import ADDBTestSupport
import Testing

@testable import ADDBCore
@testable import ADSQL

/// Aggregate projections in the `Select` DSL lower to the same function-call AST
/// the parser produces, so each builder must match the equivalent SQL string.
@Suite("SQL DSL — aggregate projections")
struct AggregateDSLTests {
    private func makeDB(_ dir: TempDir) throws -> Database {
        let db = try Database.open(at: dir.file("aggdsl.adsql"))
        try db.prepare("CREATE TABLE docs(id INTEGER PRIMARY KEY, score REAL, kind TEXT)").run()
        try db.prepare(
            "INSERT INTO docs(id, score, kind) VALUES (1,1.0,'x'),(2,2.0,'y'),(3,3.0,'x'),(4,4.0,'y'),(5,5.0,'x')"
        ).run()
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
        }.all(on: db)
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
        }.all(on: db)
        let sql = try db.prepare(
            "SELECT kind, count(*) AS n, sum(score) AS total FROM docs GROUP BY kind ORDER BY kind"
        ).all()
        #expect(dsl.map(\.values) == sql.map(\.values))
        // x: 3 rows (scores 1,3,5 → 9); y: 2 rows (2,4 → 6).
        #expect(dsl.map(\.values) == [[.text("x"), .integer(3), .real(9.0)], [.text("y"), .integer(2), .real(6.0)]])
    }
}
