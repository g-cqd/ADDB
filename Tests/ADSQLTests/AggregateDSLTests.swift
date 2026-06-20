import ADSQLModel
import Testing

@_spi(ADDBEngine) @testable import ADDBCore
@_spi(ADDBEngine) @testable import ADDBExec
@testable import ADDBTestSupport
@testable import ADSQL

/// Aggregate projections in the `Select` DSL lower to the same function-call AST
/// the parser produces, so each builder must match the equivalent SQL string.
struct AggregateDSLTests {
    private func makeDB(_ dir: TempDir) throws -> Database {
        let db = try Database.open(at: dir.file("aggdsl.adsql"))
        try db.prepare("CREATE TABLE docs(id INTEGER PRIMARY KEY, score REAL, kind TEXT)").run()
        try db.prepare(
            "INSERT INTO docs(id, score, kind) VALUES (1,1.0,'x'),(2,2.0,'y'),(3,3.0,'x'),(4,4.0,'y'),(5,5.0,'x')"
        )
        .run()
        return db
    }

    @Test func countStarMatchesSQL() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }
        let dsl = try Query {
            Select(Count().as("n"))
            From("docs")
        }
        .all(on: db)
        let sql = try db.prepare("SELECT count(*) AS n FROM docs").all()
        #expect(dsl.map(\.values) == sql.map(\.values))
        #expect(dsl[0].values == [.integer(5)])
    }

    @Test func groupedCountAndSumMatchesSQL() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }
        let dsl = try Query {
            Select(Column("kind"), Count().as("n"), Sum(Column("score")).as("total"))
            From("docs")
            GroupBy("kind")
            OrderBy("kind")
        }
        .all(on: db)
        let sql =
            try db.prepare(
                "SELECT kind, count(*) AS n, sum(score) AS total FROM docs GROUP BY kind ORDER BY kind"
            )
            .all()
        #expect(dsl.map(\.values) == sql.map(\.values))
        // x: 3 rows (scores 1,3,5 → 9); y: 2 rows (2,4 → 6).
        #expect(dsl.map(\.values) == [[.text("x"), .integer(3), .real(9.0)], [.text("y"), .integer(2), .real(6.0)]])
    }

    /// Repeated `Having` clauses must `AND`-combine, mirroring repeated `Where`.
    /// Regression: the first `Having` used to be silently overwritten by the
    /// second, so this DSL must match `HAVING count(*) >= 3 AND sum(score) <= 6`.
    ///
    /// The two predicates select *disjoint* groups (x has count 3; y has sum 6),
    /// so their `AND` matches nothing. Dropping either clause leaves a surviving
    /// group (x or y) — so any last-wins/first-wins overwrite turns this empty
    /// result non-empty, which is exactly what the old bug did.
    @Test func repeatedHavingAndCombines() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }
        let countStar = SQLExpr.function(name: "count", args: [], star: true, offset: 0)
        let sumScore = SQLExpr.function(
            name: "sum", args: [Column("score").sqlExpression], star: false, offset: 0)
        let dsl = try Query {
            Select(Column("kind"))
            From("docs")
            GroupBy("kind")
            Having(Predicate(.binary(.ge, countStar, 3.sqlExpression)))  // keeps only x
            Having(Predicate(.binary(.le, sumScore, 6.sqlExpression)))  // keeps only y
            OrderBy("kind")
        }
        .all(on: db)
        let sql =
            try db.prepare(
                "SELECT kind FROM docs GROUP BY kind HAVING count(*) >= 3 AND sum(score) <= 6 ORDER BY kind"
            )
            .all()
        #expect(dsl.map(\.values) == sql.map(\.values))
        // x: count 3, sum 9 (fails sum<=6); y: count 2 (fails count>=3), sum 6.
        // Both predicates applied → no group qualifies. If the first Having were
        // dropped (the old bug) y would survive; if the second were dropped, x would.
        #expect(dsl.isEmpty)
    }

    /// `Select` is documented as *last-wins* (a query has one projection list), in
    /// contrast to the `AND`-combining `Where`/`Having`. Pin that behavior so the
    /// asymmetry stays intentional: the final `Select` replaces earlier ones.
    @Test func repeatedSelectIsLastWins() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }
        let dsl = try Query {
            Select(Column("score"))
            Select(Column("kind"))
            From("docs")
            OrderBy("id")
        }
        .all(on: db)
        let sql = try db.prepare("SELECT kind FROM docs ORDER BY id").all()
        #expect(dsl.map(\.values) == sql.map(\.values))
        // Only the last projection (kind) survives — not a concatenation of both.
        #expect(dsl.allSatisfy { $0.values.count == 1 })
        #expect(dsl.map(\.values) == [[.text("x")], [.text("y")], [.text("x")], [.text("y")], [.text("x")]])
    }
}
