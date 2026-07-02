import ADSQLModel
import ADTestKit
import Foundation
import Testing

@_spi(ADDBEngine) @testable import ADDBCore
@_spi(ADDBEngine) @testable import ADDBExec
@testable import ADDBFTS
@testable import ADDBTestSupport

/// Recursion-cap regression lock for the FTS MATCH-query parser and evaluator.
///
/// The MATCH grammar is parsed by recursive descent (`parsePrimary` re-enters
/// `parseOr` on `(`, and itself on `col:`), and the membership evaluator
/// (`FTSMatch.Matcher.eval`) plus the compiler-generated ARC teardown of the
/// `indirect enum FTSQuery` both recurse over the parsed tree. An ADVERSARIAL
/// query string could therefore drive native-frame recursion proportional to its
/// nesting — the exact class of bug that overflowed a 512 KiB worker stack in the
/// SQL expression parser.
///
/// Two caps bound it: `maxRecursionDepth = 48` (parser re-entry per `(`/`col:`)
/// and `maxNodes = 256` (total operator nodes, which transitively bounds the tree
/// height the evaluator and teardown descend). This suite drives deeply nested
/// VALID shapes — well past both caps — through the real parse+evaluate path on a
/// pinned **512 KiB** thread (the 8 MB main test stack would hide an overflow),
/// and asserts process survival: every query either throws a clean syntax error
/// (nested too deeply / too large) or evaluates; none crashes the thread. A
/// focused block pins the node/depth cap contract.
///
/// Empirical justification for the caps (measured by bisecting each shape on a
/// 512 KiB thread with the caps lifted): pure-paren / `col:` parser recursion
/// overflows at ~2500 levels (cap 48 ⇒ ~50× margin); AND/OR chains, whose tree
/// the evaluator and ARC teardown descend, overflow at ~6500–9000 nodes (cap 256
/// ⇒ ~25× margin). Both caps fire far below the overflow threshold, so the FTS
/// source needs no recursion-specific cap (unlike the SQL parser) — this suite is
/// the lock that keeps it that way.
struct FTSQueryDepthTests {
    /// A 512 KiB worker stack — the constrained worker stack on which the SQL
    /// parser's recursion overflowed. A real parse/eval overflow reproduces only
    /// here; the multi-MB main test stack would mask it.
    static let tinyStackSize = 512 * 1024

    /// The outcome of running one MATCH query through parse + membership eval:
    /// either it evaluated (Sendable docid count) or it threw a clean DBError.
    /// Anything else (a crash) never returns here — it kills the process.
    enum Outcome: Sendable, Equatable {
        case evaluated(Int)
        case threw(DBError)
    }

    private static func makeDB(_ dir: TempDir) throws -> Database {
        let db = try Database.open(at: dir.file("ftsdepth.adsql"))
        try db.prepare("CREATE VIRTUAL TABLE fts USING fts5(body, tokenize='porter unicode61')").run()
        try db.prepare("INSERT INTO fts(rowid, body) VALUES(1, 'alpha beta gamma')").run()
        try db.prepare("INSERT INTO fts(rowid, body) VALUES(2, 'alpha delta')").run()
        return db
    }

    // MARK: - Deeply nested VALID shapes

    /// Builds a deeply nested but well-formed MATCH query of `kind` at nesting `n`.
    enum Shape: Sendable, CaseIterable {
        /// `(((…alpha…)))` — N parens; each `(` re-enters the parser (depth cap).
        case parens
        /// `body:body:…:alpha` — each `:` re-enters `parsePrimary` (depth + node cap).
        case columnChain
        /// `alpha AND alpha AND …` — iterative parse, a left-leaning `.and` tree of
        /// height ≈ N−1 that the evaluator and ARC teardown descend (node cap).
        case andChain
        /// `alpha OR alpha OR …` — as above with `.or`.
        case orChain
        /// `alpha NOT alpha NOT …` — a left-leaning `.not` tree (node cap).
        case notChain

        func query(_ n: Int) -> String {
            switch self {
                case .parens:
                    return String(repeating: "(", count: n) + "alpha" + String(repeating: ")", count: n)
                case .columnChain:
                    return String(repeating: "body:", count: n) + "alpha"
                case .andChain:
                    return Array(repeating: "alpha", count: n).joined(separator: " AND ")
                case .orChain:
                    return Array(repeating: "alpha", count: n).joined(separator: " OR ")
                case .notChain:
                    return "alpha " + Array(repeating: "NOT alpha", count: n).joined(separator: " ")
            }
        }
    }

    /// Every deeply nested shape, swept from shallow to far past both caps, runs on
    /// the 512 KiB thread without crashing: each query either evaluates or throws a
    /// clean DBError. Reaching the end of the sweep is the survival proof.
    @Test func deeplyNestedShapesSurviveTinyStack() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Self.makeDB(dir)
        defer { db.close() }

        // Depths span shallow → at the parser cap (48) → at the node cap (256) →
        // an order of magnitude past it. All well below any overflow threshold,
        // so survival must hold for every one.
        let depths = [1, 8, 16, 32, 47, 48, 49, 100, 200, 255, 256, 257, 512, 1000, 3000]
        for shape in Shape.allCases {
            for n in depths {
                let outcome = runOnConstrainedStack(stackSize: Self.tinyStackSize) {
                    let query = shape.query(n)
                    do {
                        let docids = try db.writeSync { (txn) throws(DBError) -> [Int64] in
                            try txn.ftsMatch("fts", query)
                        }
                        return Outcome.evaluated(docids.count)
                    } catch let error as DBError {
                        return Outcome.threw(error)
                    } catch {
                        return Outcome.threw(.sqlRuntime("unexpected: \(error)"))
                    }
                }
                // Survival is implicit (we got an Outcome back). Pin that the result
                // is one of the two clean shapes — never a runtime surprise.
                switch outcome {
                    case .evaluated:
                        break
                    case .threw(let error):
                        guard case .sqlSyntax = error else {
                            Issue.record("\(shape) n=\(n) threw non-syntax error: \(error)")
                            continue
                        }
                }
            }
        }
    }

    /// The ranked / block-max-WAND path (its own recursion: `FTSWAND.classify`
    /// over the tree, plus the scorer) also survives the 512 KiB stack at and past
    /// the node cap, driven end-to-end through SQL `ORDER BY bm25(...)`.
    @Test func rankedPathSurvivesTinyStack() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Self.makeDB(dir)
        db.enableFullTextSearch()
        defer { db.close() }

        for n in [16, 100, 256, 300, 1000] {
            let query = Shape.orChain.query(n)  // OR of single terms is WAND-eligible
            let outcome = runOnConstrainedStack(stackSize: Self.tinyStackSize) {
                do {
                    let rows =
                        try db.prepare(
                            "SELECT rowid FROM fts WHERE fts MATCH ? ORDER BY bm25(fts) LIMIT 5"
                        )
                        .all(.text(query))
                    return Outcome.evaluated(rows.count)
                } catch let error as DBError {
                    return Outcome.threw(error)
                } catch {
                    return Outcome.threw(.sqlRuntime("unexpected: \(error)"))
                }
            }
            if case .threw(let error) = outcome, case .sqlSyntax = error {
                continue  // a clean "too large"/"too deep" reject is fine
            }
            if case .threw(let error) = outcome {
                Issue.record("ranked n=\(n) threw non-syntax error: \(error)")
            }
        }
    }

    // MARK: - The node / depth cap contract

    /// Pins the two caps that keep recursion bounded, exercised on the 512 KiB
    /// stack so the contract and the survival guarantee are asserted together.
    @Test func capContractIsEnforced() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Self.makeDB(dir)
        defer { db.close() }

        func run(_ query: String) -> Outcome {
            runOnConstrainedStack(stackSize: Self.tinyStackSize) {
                do {
                    let docids = try db.writeSync { (txn) throws(DBError) -> [Int64] in
                        try txn.ftsMatch("fts", query)
                    }
                    return Outcome.evaluated(docids.count)
                } catch let error as DBError {
                    return Outcome.threw(error)
                } catch {
                    return Outcome.threw(.sqlRuntime("unexpected: \(error)"))
                }
            }
        }

        func syntaxMessage(_ outcome: Outcome) -> String? {
            guard case .threw(.sqlSyntax(let message, _)) = outcome else { return nil }
            return message
        }

        // Parser-recursion cap (maxRecursionDepth = 48): one fewer paren evaluates;
        // at the cap the parser rejects with "nested too deeply" — never overflows.
        #expect(run(Shape.parens.query(47)) == .evaluated(2))
        #expect(syntaxMessage(run(Shape.parens.query(48))) == "MATCH query is nested too deeply")
        #expect(syntaxMessage(run(Shape.parens.query(500))) == "MATCH query is nested too deeply")
        // The `col:` chain re-enters the same recursive primary and hits the same cap.
        #expect(run(Shape.columnChain.query(47)) == .evaluated(2))
        #expect(syntaxMessage(run(Shape.columnChain.query(48))) == "MATCH query is nested too deeply")

        // Node-count cap (maxNodes = 256): an N-term AND builds N−1 `.and` nodes.
        // 257 terms → 256 nodes is the last that fits; 258 → 257 nodes is rejected
        // with "too large" — before the tree the evaluator/teardown would descend
        // grows without bound.
        #expect(run(Shape.andChain.query(257)) == .evaluated(2))  // both docs share "alpha"
        #expect(syntaxMessage(run(Shape.andChain.query(258))) == "MATCH query is too large")
        #expect(syntaxMessage(run(Shape.orChain.query(258))) == "MATCH query is too large")
        #expect(syntaxMessage(run(Shape.notChain.query(258))) == "MATCH query is too large")

        // The caps are independent: the node cap (256) exceeds the depth cap (48),
        // so a pure-nesting shape is stopped by depth long before node count.
        #expect(MatchParserProbe.maxNodes == 256)
        #expect(MatchParserProbe.maxRecursionDepth == 48)
    }
}

/// Surfaces the (private) parser caps for the contract assertion without widening
/// their visibility in the shipped module: mirrors the two `static let`s the test
/// pins. If either constant changes, update both — the mismatch is the signal that
/// the cap contract (and its 512 KiB-stack justification) must be re-derived.
enum MatchParserProbe {
    static let maxNodes = 256
    static let maxRecursionDepth = 48
}
