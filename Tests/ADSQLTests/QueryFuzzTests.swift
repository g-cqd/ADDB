import ADSQLModel
import Foundation
import Testing

// Scope-import only `SeededRNG` to avoid a name clash with `ADDBTestSupport.TempDir`,
// which this suite also uses. `SeededRNG`'s `int` / `int(in:)` / `pick` / `bool` match
// the old local `SeededRNG` byte-for-byte, so this seed reproduces the identical corpus.
import struct ADTestKit.SeededRNG

@_spi(ADDBEngine) @testable import ADDBCore
@_spi(ADDBEngine) @testable import ADDBExec
@testable import ADDBTestSupport
@testable import ADSQL

/// Deterministic, seeded SQL FUZZ. Proves the parser/binder/executor NEVER trap,
/// hang, OOM, or stack-overflow on adversarial query text plus bound values: a
/// generated statement may only throw a `DBError` (sqlSyntax / sqlUnsupported /
/// sqlBind / sqlRuntime / etc.) or return a well-formed result. The PASS condition
/// is process survival — a `precondition` / `fatalError` / stack-overflow / hang
/// would crash or wedge the test, which is exactly the signal of an unhardened
/// DoS vector.
///
/// This locks the DoS hardening around parser/binder/executor depth:
///   - `Statement.maxSubqueryDepth = 16` — a runtime cap on correlated
///     scalar-subquery re-entrancy (deep correlated nesting throws `sqlRuntime`,
///     not stack-overflow / N^depth wall-clock).
///   - `SQLParser.maxRecursionDepth = 16` — the cap on *recursive-primary* nesting
///     (every primary that re-enters `expression`: a scalar subquery `(SELECT …)`,
///     `CASE`, `CAST`, `IN (…)`, function args). This is the cap this fuzz drove the
///     parser into adding: nested `(SELECT (SELECT …))` and deep nested `CASE`
///     overflowed the parse stack (SIGBUS) at a couple dozen levels before it
///     existed; now they throw `sqlSyntax`.
///   - `SQLParser.maxExprDepth = 48` (iterative paren / prefix / binary frames on
///     `climb`'s heap stack) and `SQLParser.maxExpressionTreeDepth = 256` (AST
///     height) — absurdly deep parens / boolean chains throw `sqlSyntax`, not
///     overflow.
///   - The recursive AST consumers (`Binder.bindColumns`, JSONPath `evalFilter`)
///     are bounded by those caps; the JSON SQL functions route through ADJSON's
///     JSONPath/JSONPointer, which carry their own depth caps, so adversarial
///     `json_extract` / `->` / `->>` path strings must not trap.
///
/// Reproducibility: a fixed SeededRNG seed (NOT `SystemRandomNumberGenerator`),
/// so any failure reproduces. Set `ADSQL_FUZZ_TRACE` in the environment to print
/// every generated statement; a crash's last printed line is then the repro.
struct QueryFuzzTests {
    // MARK: - Deterministic PRNG (shared `ADTestKit.SeededRNG`)

    /// The fixed seed and iteration budget. ~4000 iterations of generate +
    /// prepare + run stays well under the ~15s bound while sweeping every cap
    /// boundary many times over.
    private static let seed: UInt64 = 0x5DEE_CE66_D0DC_2F1B
    private static let iterations = 4000

    // MARK: - Fixture

    /// In-process temp DB with two small tables so joins / subqueries bind, plus a
    /// TEXT column holding JSON so `json_extract` paths have real input. JSON is
    /// enabled (process-wide, idempotent) so `->` / `->>` / `json_extract` route
    /// through ADJSON rather than failing fast as unsupported.
    private static let setup = [
        """
        CREATE TABLE docs(
          id INTEGER PRIMARY KEY, root_id INTEGER, title TEXT, body TEXT, meta TEXT)
        """,
        "CREATE TABLE roots(id INTEGER PRIMARY KEY, slug TEXT)",
        "INSERT INTO roots VALUES(1,'UIKit'),(2,'SwiftUI'),(3,'Empty')",
        """
        INSERT INTO docs VALUES
          (1,1,'Button','a body','{"year":2020,"tags":["ui","kit"],"nested":{"x":1}}'),
          (2,1,'Stack','b body','{"year":2021,"beta":true}'),
          (3,2,'View','c body','{"year":2019}'),
          (4,2,'Data','d body','not json'),
          (5,3,'Empty',NULL,NULL)
        """
    ]

    private func build(_ dir: TempDir) throws -> Database {
        let db = try Database.openJSON(at: dir.file("fuzz.adsql"))
        for sql in Self.setup { try db.prepare(sql).run() }
        return db
    }

    // MARK: - Token alphabet for byte/token mutation

    /// A pool of seed queries that all parse and bind against the fixture; byte and
    /// token mutation perturbs these toward malformed / pathological shapes.
    private static let seedQueries = [
        "SELECT id, title FROM docs WHERE root_id = ? ORDER BY id",
        "SELECT COUNT(*) FROM docs d JOIN roots r ON d.root_id = r.id",
        "SELECT id FROM docs WHERE title LIKE ? AND id IN (1, 2, 3)",
        "SELECT id, (SELECT COUNT(*) FROM docs x WHERE x.root_id = docs.root_id) FROM docs",
        "SELECT json_extract(meta, '$.year') FROM docs WHERE meta IS NOT NULL",
        "SELECT meta -> '$.tags' ->> '$[0]' FROM docs",
        "SELECT CASE WHEN id > 2 THEN 'hi' ELSE 'lo' END FROM docs",
        "SELECT slug FROM roots WHERE id = ? UNION SELECT title FROM docs WHERE id = ?",
        "SELECT id FROM docs GROUP BY root_id HAVING COUNT(*) > 0",
        "UPDATE docs SET title = ? WHERE id = ?"
    ]

    /// Bytes mutation may splice in: quotes, parens, operators, keywords — the
    /// characters most likely to imbalance the grammar or reach an unguarded path.
    private static let mutationBytes: [UInt8] = Array(
        "()[]{}'\"`;,.*-+/<>=!?|&%$@:\\\n\t".utf8)

    // MARK: - Random bound values

    /// A grab-bag of bound parameter values, including extreme integers, an
    /// adversarial JSON-path-shaped string, and a blob — anything a `?` might receive.
    private func randomValue(_ rng: inout SeededRNG) -> Value {
        switch rng.int(7) {
            case 0: return .null
            case 1: return .integer(Int64(rng.int(in: -5 ... 5)))
            case 2: return .integer(rng.bool() ? .max : .min)
            case 3: return .real(rng.bool() ? 0 : Double.infinity)
            case 4: return .text("")
            case 5: return .text(adversarialJSONPath(&rng))
            default: return .blob([0, 1, 2, 0xFF])
        }
    }

    /// Binds `count` random values for the positional `?` markers a query carries.
    private func randomParams(_ count: Int, _ rng: inout SeededRNG) -> [Value] {
        var values: [Value] = []
        values.reserveCapacity(count)
        for _ in 0 ..< count { values.append(randomValue(&rng)) }
        return values
    }

    // MARK: - Grammar-aware generators

    /// Depths sweep from comfortably-legal up to far past every cap (parser caps at
    /// 48 / 256, the subquery runtime cap at 16), so the boundary is crossed from
    /// both sides many times across the corpus.
    private func sampleDepth(_ rng: inout SeededRNG) -> Int {
        switch rng.int(6) {
            case 0: return rng.int(in: 1 ... 8)  // trivially legal
            case 1: return rng.int(in: 12 ... 20)  // around the subquery cap
            case 2: return rng.int(in: 40 ... 60)  // around maxExprDepth
            case 3: return rng.int(in: 240 ... 280)  // around maxExpressionTreeDepth
            default: return rng.int(in: 300 ... 2000)  // absurd — well past every cap
        }
    }

    /// `(((( … 1 … ))))` — N balanced parens around a literal. Stresses the static
    /// nesting cap and the parenthesised-group teardown.
    private func nestedParens(_ depth: Int) -> String {
        "SELECT " + String(repeating: "(", count: depth) + "1" + String(repeating: ")", count: depth)
    }

    /// `1 AND 1 AND … 1` (or OR) — a long left-leaning boolean chain that builds a
    /// tall AST, stressing `maxExpressionTreeDepth` incrementally during the climb.
    private func booleanChain(_ depth: Int, _ rng: inout SeededRNG) -> String {
        let op = rng.bool() ? " AND " : " OR "
        return "SELECT id FROM docs WHERE "
            + Array(repeating: "1", count: depth + 1).joined(separator: op)
    }

    /// N-deep nested `CASE WHEN <cond> THEN <nested> ELSE 0 END`.
    private func nestedCase(_ depth: Int) -> String {
        var inner = "0"
        for level in 0 ..< depth {
            inner = "CASE WHEN id > \(level) THEN \(inner) ELSE 0 END"
        }
        return "SELECT \(inner) FROM docs"
    }

    /// N-deep nested *uncorrelated* scalar subqueries: `(SELECT (SELECT … 1 … ))`.
    private func nestedScalarSubquery(_ depth: Int) -> String {
        var inner = "SELECT 1"
        for _ in 0 ..< depth { inner = "SELECT (\(inner))" }
        return "SELECT (\(inner))"
    }

    /// N-deep nested *correlated* scalar subqueries, each referencing the outer
    /// table — the shape `maxSubqueryDepth` exists to bound. Past depth 16 this must
    /// throw `sqlRuntime`, never recurse the executor into a stack overflow.
    private func nestedCorrelatedSubquery(_ depth: Int) -> String {
        var inner = "SELECT COUNT(*) FROM docs t\(depth) WHERE t\(depth).root_id = docs.id"
        for level in stride(from: depth - 1, through: 0, by: -1) {
            inner =
                "SELECT (\(inner)) FROM docs t\(level) WHERE t\(level).root_id = docs.id"
        }
        return "SELECT id, (\(inner)) FROM docs"
    }

    /// An adversarial `json_extract(col, ?)` over a deep / malformed path string —
    /// exercises the ADJSON JSONPath caps without trapping.
    private func jsonExtractFuzz(_ rng: inout SeededRNG) -> String {
        if rng.bool() {
            return "SELECT json_extract(meta, ?) FROM docs"
        }
        // Inline an extreme literal path so the parser/JSONPath see it directly.
        return "SELECT json_extract(meta, '\(adversarialJSONPath(&rng))') FROM docs"
    }

    /// A pathological JSONPath-shaped string: deep `.a.a.…`, deep `[0][0]…`, deep
    /// wildcards/recursive descent, or an unbalanced fragment. Used both as a bound
    /// `?` value and as an inline literal path.
    private func adversarialJSONPath(_ rng: inout SeededRNG) -> String {
        let depth = sampleDepth(&rng)
        switch rng.int(5) {
            case 0: return "$" + String(repeating: ".a", count: depth)
            case 1: return "$" + String(repeating: "[0]", count: depth)
            case 2: return "$" + String(repeating: "[#-1]", count: depth)
            case 3: return "$" + String(repeating: ".*", count: depth)  // wildcard run
            default: return "$" + String(repeating: "[", count: depth)  // unbalanced
        }
    }

    /// Routes to one grammar-aware generator, each emitting a parseable-but-extreme
    /// shape at a swept depth.
    private func generateGrammar(_ rng: inout SeededRNG) -> String {
        let depth = sampleDepth(&rng)
        switch rng.int(7) {
            case 0: return nestedParens(depth)
            case 1: return booleanChain(depth, &rng)
            case 2: return nestedCase(depth)
            case 3: return nestedScalarSubquery(depth)
            case 4: return nestedCorrelatedSubquery(depth)
            case 5: return jsonExtractFuzz(&rng)
            default:
                // Compose two stressors so caps interact (deep parens around a chain).
                return "SELECT " + String(repeating: "(", count: depth) + "1"
                    + String(repeating: " AND 1", count: rng.int(in: 1 ... 64))
                    + String(repeating: ")", count: depth)
        }
    }

    // MARK: - Byte / token mutation

    /// Mutates a valid seed query toward malformed input: random substitutions,
    /// insertions, deletions, and quote/paren imbalancing. Operates on UTF-8 bytes
    /// so it can produce invalid-but-survivable token streams.
    private func mutate(_ rng: inout SeededRNG) -> String {
        var bytes = Array(rng.pick(Self.seedQueries).utf8)
        let edits = rng.int(in: 1 ... 12)
        for _ in 0 ..< edits {
            guard !bytes.isEmpty else { break }
            switch rng.int(4) {
                case 0:  // substitute
                    bytes[rng.int(bytes.count)] = rng.pick(Self.mutationBytes)
                case 1:  // insert
                    bytes.insert(rng.pick(Self.mutationBytes), at: rng.int(bytes.count + 1))
                case 2:  // delete
                    bytes.remove(at: rng.int(bytes.count))
                default:  // imbalance: splice a run of one structural byte
                    let byte = rng.pick(Array("()'\"".utf8))
                    let run = rng.int(in: 1 ... 8)
                    bytes.insert(contentsOf: Array(repeating: byte, count: run), at: rng.int(bytes.count + 1))
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Driver

    /// Prepares and executes one generated statement, swallowing any `DBError`
    /// (expected and fine). A SELECT/compound is read with `all`; anything else
    /// runs for effect. Returning normally means the vector survived.
    private func drive(_ db: Database, _ sql: String, _ params: [Value]) {
        // The whole SQL surface is `throws(DBError)`, so a typed do/catch binds the
        // error as `DBError`: any rejection here is the desired typed error, not a
        // trap. Survival (returning normally) is the PASS condition.
        do throws(DBError) {
            let statement = try db.prepare(sql)
            if statement.isReadOnly {
                _ = try statement.all(SQLParameters(positional: params))
            } else {
                _ = try statement.run(SQLParameters(positional: params))
            }
        } catch {
            // Adversarial input rejected as a typed error — expected and fine.
        }
    }

    @Test
    func `adversarial query text never traps`() throws {
        let trace = ProcessInfo.processInfo.environment["ADSQL_FUZZ_TRACE"] != nil
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try build(dir)
        defer { db.close() }

        var rng = SeededRNG(seed: Self.seed)
        for iteration in 0 ..< Self.iterations {
            // ~70% grammar-aware extreme shapes, ~30% byte/token mutation.
            let sql = rng.int(10) < 7 ? generateGrammar(&rng) : mutate(&rng)
            // Bind a random value per `?` so parameterised shapes exercise binding too.
            let placeholders = sql.utf8.reduce(into: 0) { count, byte in
                if byte == UInt8(ascii: "?") { count += 1 }
            }
            let params = randomParams(placeholders, &rng)
            if trace {
                // The last line printed before a crash is the exact repro.
                print("ADSQL_FUZZ[\(iteration)]: \(sql)  params=\(params)")
            }
            drive(db, sql, params)
        }
    }

    // MARK: - Focused cap contracts

    /// Asserts `prepare` rejects `sql` with a `sqlSyntax` error (the parser
    /// depth-cap contract) rather than trapping.
    private func expectSyntaxError(_ db: Database, _ sql: String, _ note: String) {
        var caught: DBError?
        do throws(DBError) {
            _ = try db.prepare(sql).all()
        } catch {
            caught = error
        }
        if case .sqlSyntax = caught {
            // Expected: a parser depth cap fired.
        } else {
            Issue.record("expected sqlSyntax \(note), got \(String(describing: caught))")
        }
    }

    /// Recursive primaries — nested scalar subqueries and nested CASE (reusing the
    /// grammar generators above) — past `SQLParser.maxRecursionDepth` must throw
    /// `sqlSyntax`, not overflow the parse stack. Each such primary re-enters
    /// `expression`, so `maxRecursionDepth` bounds that native recursion. Before it
    /// was added, ~23 nested subqueries (and ~37 nested CASE) overflowed the stack
    /// (SIGBUS) *during parsing* — the vectors this fuzz found and locked.
    @Test
    func `recursive primaries past the recursion-depth cap throw sqlSyntax`() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try build(dir)
        defer { db.close() }

        // Just past the cap, and absurdly past it, must both be syntax errors.
        for depth in [SQLParser.maxRecursionDepth + 1, 2000] {
            expectSyntaxError(
                db, nestedScalarSubquery(depth), "past maxRecursionDepth (nested subquery, depth \(depth))")
            expectSyntaxError(db, nestedCase(depth), "past maxRecursionDepth (nested CASE, depth \(depth))")
        }
    }

    /// Nesting *up to* the cap still parses and runs — the cap rejects only the
    /// pathological depth, never legitimate (if unusual) nesting. Nested CASE at
    /// `maxRecursionDepth - 1` levels evaluates cleanly over the fixture rows.
    @Test
    func `nesting up to the recursion-depth cap still runs`() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try build(dir)
        defer { db.close() }
        let rows = try db.prepare(nestedCase(SQLParser.maxRecursionDepth - 1)).all()
        #expect(rows.count == 5)  // one value per fixture row, no trap
    }

    /// A plain parenthesised / boolean expression nested past
    /// `SQLParser.maxExpressionTreeDepth` (the AST-height cap, distinct from the
    /// recursive-primary cap — deep parens do NOT re-enter `expression`) must throw
    /// `sqlSyntax`, not overflow on the deep `indirect enum` graph.
    @Test
    func `deep expression tree past the height cap throws sqlSyntax`() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try build(dir)
        defer { db.close() }

        let depth = SQLParser.maxExpressionTreeDepth + 64
        let parens =
            "SELECT " + String(repeating: "(", count: depth) + "1"
            + String(repeating: ")", count: depth)
        expectSyntaxError(db, parens, "past maxExpressionTreeDepth (deep parens)")

        let chain =
            "SELECT id FROM docs WHERE "
            + Array(repeating: "1", count: depth).joined(separator: " AND ")
        expectSyntaxError(db, chain, "past maxExpressionTreeDepth (AND chain)")
    }
}
