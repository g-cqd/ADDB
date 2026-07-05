import ADSQL
import ADSQLModel
import Testing

@_spi(ADDBEngine) @testable import ADDBCore
@_spi(ADDBEngine) @testable import ADDBExec
@testable import ADDBTestSupport

/// The cross-strategy differential gate: the SAME query must produce identical
/// results under every execution strategy AND match the SQLite oracle. This is
/// the accuracy/consistency safety net that lets alternative strategies (here the
/// compiled-closure evaluator) be added beside the reference tree-walk path. As
/// more strategies land (hash/merge join, VDBE, insert paths) they join the matrix.
private enum MatrixFixture {
    static let columns = ["id", "name", "tag", "score", "weight"]

    static let definition = TableDefinition(
        "t",
        columns: [
            ColumnDefinition("id", .integer, notNull: true),
            ColumnDefinition("name", .text, notNull: true),  // BINARY
            ColumnDefinition("tag", .text, collation: .nocase),  // NOCASE, NULLs
            ColumnDefinition("score", .integer),  // NULLs
            ColumnDefinition("weight", .real)  // NULLs
        ],
        primaryKey: .rowidAlias(column: "id", autoincrement: true))

    static let sqliteDDL = """
        CREATE TABLE t(
          id INTEGER PRIMARY KEY, name TEXT NOT NULL, tag TEXT COLLATE NOCASE,
          score INTEGER, weight REAL)
        """

    static let names = ["alpha", "Bravo", "charlie", "Delta", "echo"]
    static let tags = ["X", "y", "Z"]

    static func rows() -> [[Value]] {
        (1 ... 25)
            .map { i in
                let tag: Value = i % 6 == 0 ? .null : .text(tags[i % tags.count])
                let score: Value = i % 5 == 0 ? .null : .integer(Int64(i % 8) - 3)
                let weight: Value = i % 4 == 0 ? .null : .real(Double(i) / 2 - 5)
                return [.integer(Int64(i)), .text(names[i % names.count]), tag, score, weight]
            }
    }

    // A second table for the join scenarios. `ref` mostly points at a real `t.id`
    // (INNER matches + LEFT null-extensions on the `t` rows nobody references) with a
    // couple of dangling refs (28, 26) that match nothing. `label` is NOCASE so a
    // `u.label = t.tag` ON conjunct exercises collation resolution across tables.
    static let uColumns = ["uid", "ref", "label", "amount"]

    static let uDefinition = TableDefinition(
        "u",
        columns: [
            ColumnDefinition("uid", .integer, notNull: true),
            ColumnDefinition("ref", .integer),  // → t.id (some dangling)
            ColumnDefinition("label", .text, collation: .nocase),  // NOCASE, matches tags
            ColumnDefinition("amount", .integer)  // NULLs
        ],
        primaryKey: .rowidAlias(column: "uid", autoincrement: true))

    static let uSqliteDDL = """
        CREATE TABLE u(
          uid INTEGER PRIMARY KEY, ref INTEGER, label TEXT COLLATE NOCASE, amount INTEGER)
        """

    static let labels = ["x", "Y", "z"]  // NOCASE-equal to the `t.tags`

    static func uRows() -> [[Value]] {
        (1 ... 15)
            .map { j in
                let ref = Value.integer(Int64((j * 7) % 30))  // 1..28; 28 and 26 dangle
                let label = Value.text(labels[j % labels.count])
                let amount: Value = j % 5 == 0 ? .null : .integer(Int64((j * 3) % 20))
                return [.integer(Int64(j)), ref, label, amount]
            }
    }

    static func make(_ dir: TempDir, evaluator: ExecutionOptions.Evaluator) throws -> Database {
        let db = try Database.open(
            at: dir.file("matrix-\(evaluator).adsql"),
            options: DatabaseOptions(execution: ExecutionOptions(evaluator: evaluator)))
        try db.writeSync { (txn) throws(DBError) in
            try txn.createTable(definition)
            try txn.createTable(uDefinition)
        }
        for row in rows() {
            let dict = Dictionary(uniqueKeysWithValues: zip(columns, row))
            try db.writeSync { (txn) throws(DBError) in try txn.insert(into: "t", dict) }
        }
        for row in uRows() {
            let dict = Dictionary(uniqueKeysWithValues: zip(uColumns, row))
            try db.writeSync { (txn) throws(DBError) in try txn.insert(into: "u", dict) }
        }
        return db
    }

    static func mirror() throws -> SQLiteMirror {
        let m = SQLiteMirror()
        try m.exec(sqliteDDL)
        try m.exec(uSqliteDDL)
        for row in rows() { try m.insertRow("t", columns, row) }
        for row in uRows() { try m.insertRow("u", uColumns, row) }
        return m
    }
}

struct SQLStrategyMatrixTests {
    static let evaluators: [ExecutionOptions.Evaluator] = [.treeWalk, .compiledClosures]

    static let queries: [String] = [
        "SELECT id, name FROM t WHERE score > 2 ORDER BY id",  // comparison + numeric affinity
        "SELECT id FROM t WHERE name = 'Bravo' ORDER BY id",  // TEXT BINARY compare
        "SELECT id, tag FROM t WHERE tag = 'x' ORDER BY id",  // TEXT NOCASE compare
        "SELECT id, score * 2 AS d FROM t WHERE score IS NOT NULL ORDER BY id",  // arithmetic + IS NULL
        "SELECT id FROM t WHERE score >= 0 AND weight < 0 ORDER BY id",  // AND + mixed types + NULLs
        "SELECT id FROM t WHERE score > 3 OR name = 'alpha' ORDER BY id",  // OR
        "SELECT id, CASE WHEN score > 2 THEN 'hi' WHEN score < 0 THEN 'lo' ELSE 'mid' END AS c FROM t ORDER BY id",
        "SELECT id FROM t WHERE -score > 0 ORDER BY id",  // unary negate
        "SELECT id FROM t WHERE CAST(score AS TEXT) = '4' ORDER BY id",  // cast
        "SELECT id, name FROM t WHERE name >= 'a' ORDER BY name, id LIMIT 4",  // bounded top-N (total order)
        "SELECT DISTINCT tag FROM t",  // distinct projection (NOCASE)
        "SELECT id FROM t WHERE name = 'Bravo' COLLATE NOCASE ORDER BY id",  // explicit COLLATE
        "SELECT id, name || '!' AS n FROM t WHERE id <= 3 ORDER BY id",  // concat
        // Newly compiled cases (R3): LIKE, IN-list, scalar functions — each must stay
        // compiled ≡ tree-walk ≡ SQLite, including NULL 3VL and collation.
        "SELECT id, name FROM t WHERE name LIKE 'a%' ORDER BY id",  // LIKE prefix (ASCII case-insensitive)
        "SELECT id FROM t WHERE name NOT LIKE 'B%' ORDER BY id",  // NOT LIKE
        "SELECT id, tag FROM t WHERE tag LIKE '%' ORDER BY id",  // LIKE over NULLs (NULL ⇒ no match)
        "SELECT id FROM t WHERE score IN (1, 2, 3) ORDER BY id",  // IN integer list
        "SELECT id FROM t WHERE name IN ('alpha', 'Delta') ORDER BY id",  // IN TEXT list (BINARY)
        "SELECT id, tag FROM t WHERE tag IN ('x', 'z') ORDER BY id",  // IN under the column's NOCASE collation
        "SELECT id FROM t WHERE score NOT IN (0, 1) ORDER BY id",  // NOT IN (NULL lhs ⇒ unknown)
        "SELECT id FROM t WHERE score IN (NULL, 2) ORDER BY id",  // NULL in the list (3VL)
        "SELECT id, upper(name) AS u FROM t WHERE id <= 4 ORDER BY id",  // scalar function projection
        "SELECT id FROM t WHERE length(name) > 4 ORDER BY id",  // function in WHERE
        "SELECT id FROM t WHERE upper(name) = 'ALPHA' ORDER BY id",  // function inside a compiled comparison
        "SELECT id, coalesce(score, -99) AS s FROM t ORDER BY id",  // coalesce over NULLs
        // Newly compiled cases (FIX #2): JOIN + GROUP BY / HAVING. The ON / WHERE /
        // group-key / join-output / join-order-by expressions evaluate against a
        // RowContext, so `CompiledEval` targets them; the aggregate HAVING / output /
        // order-by evaluate against the aggregate env and stay tree-walk. Each must
        // remain compiled ≡ tree-walk ≡ SQLite, including LEFT null-extension, NOCASE
        // cross-table compares, and NULL 3VL in the ON/WHERE.
        "SELECT t.id, u.label FROM t JOIN u ON u.ref = t.id ORDER BY t.id, u.uid",  // INNER, single-conjunct ON
        "SELECT t.id, u.amount FROM t LEFT JOIN u ON u.ref = t.id ORDER BY t.id, u.uid",  // LEFT null-extension
        "SELECT t.id, u.uid FROM t JOIN u ON u.ref = t.id AND u.amount > 5 ORDER BY t.id, u.uid",  // multi-conjunct ON
        "SELECT t.id, u.label FROM t JOIN u ON u.ref = t.id WHERE t.score > 0 ORDER BY t.id, u.uid",  // ON + residual WHERE
        "SELECT t.id, u.amount + t.score AS s FROM t JOIN u ON u.ref = t.id ORDER BY t.id, u.uid",  // join output expr
        "SELECT t.id, u.uid FROM t JOIN u ON u.ref = t.id AND u.label = t.tag ORDER BY t.id, u.uid",  // NOCASE cross-table ON
        "SELECT t.name, u.label FROM t JOIN u ON u.ref = t.id WHERE u.amount IS NOT NULL ORDER BY t.id, u.uid",  // WHERE on inner col
        "SELECT tag, count(*), sum(score) FROM t GROUP BY tag ORDER BY tag",  // grouped aggregate over NULL group
        "SELECT tag, count(*) AS c FROM t GROUP BY tag HAVING count(*) >= 3 ORDER BY tag",  // HAVING on aggregate
        "SELECT name, count(*), avg(weight) FROM t GROUP BY name ORDER BY name",  // avg REAL + text group key
        "SELECT tag, sum(score) AS ss FROM t GROUP BY tag HAVING sum(score) > 0 OR tag = 'X' ORDER BY tag",  // HAVING agg + key
        "SELECT count(*), sum(score), avg(weight), max(score), min(score) FROM t WHERE score IS NOT NULL",  // ungrouped multi-agg + WHERE
        "SELECT score, count(*) FROM t WHERE score IS NOT NULL GROUP BY score ORDER BY score",  // integer group key + WHERE
        "SELECT t.tag, count(*), sum(u.amount) FROM t JOIN u ON u.ref = t.id GROUP BY t.tag ORDER BY t.tag",  // aggregate over join
        "SELECT t.tag, count(*) AS c FROM t JOIN u ON u.ref = t.id GROUP BY t.tag HAVING count(*) > 1 ORDER BY t.tag"  // join + GROUP BY + HAVING
    ]

    @Test(arguments: queries)
    func everyEvaluatorAgreesAndMatchesSQLite(_ sql: String) throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let mirror = try MatrixFixture.mirror()
        let theirs = try mirror.query(sql)
        let ordered = sql.lowercased().contains("order by")

        var reference: [[Value]]?
        for evaluator in Self.evaluators {
            let db = try MatrixFixture.make(dir, evaluator: evaluator)
            defer { db.close() }
            let ours = try db.prepare(sql).all().map(\.values)
            // Every strategy must match the external oracle …
            #expect(rowsMatch(ours, theirs, ordered: ordered), "\(evaluator) \(sql): \(ours) vs sqlite \(theirs)")
            // … and produce identical results to the reference strategy.
            if let reference {
                #expect(rowsMatch(ours, reference, ordered: ordered), "\(evaluator) diverged on \(sql)")
            } else {
                reference = ours
            }
        }
    }

    /// A deep WHERE chain exercises the whole pipeline (binder ref-walks, planner
    /// conjunct split, invariant folding, and both evaluators) iteratively. Within
    /// the depth bound it runs and agrees across evaluators; past the bound it is
    /// rejected at prepare under every evaluator — never overflowing a consumer or
    /// the recursive `indirect enum` teardown. The cap-legal 250-term chain recurses
    /// the binder once per term, so each sweep runs on the explicit depth-sweep
    /// thread (see DepthSweepSupport.swift); assertions stay on the test task.
    @Test func deepWhereChainUnderEveryEvaluator() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let within = Array(repeating: "id >= 1", count: 250).joined(separator: " AND ")
        let overlong = Array(repeating: "id >= 1", count: 5000).joined(separator: " AND ")
        var reference: [[Value]]?
        for evaluator in Self.evaluators {
            let (rows, rejectedOverlong) = try runDepthSweep { () throws -> ([[Value]], Bool) in
                let db = try MatrixFixture.make(dir, evaluator: evaluator)
                defer { db.close() }
                let rows = try db.prepare("SELECT count(*) FROM t WHERE \(within)").all().map(\.values)
                var threw = false
                do { _ = try db.prepare("SELECT count(*) FROM t WHERE \(overlong)") } catch { threw = true }
                return (rows, threw)
            }
            if let reference {
                #expect(rowsMatch(rows, reference, ordered: false), "\(evaluator)")
            } else {
                reference = rows
            }
            #expect(rejectedOverlong, "\(evaluator) should reject the overlong WHERE")
        }
        #expect(reference == [[.integer(25)]])  // all 25 rows match the within-limit chain
    }
}
