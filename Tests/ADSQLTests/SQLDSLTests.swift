import ADSQLModel
import Testing

@_spi(ADDBEngine) @testable import ADDBCore
@_spi(ADDBEngine) @testable import ADDBExec
@testable import ADDBTestSupport
@testable import ADSQL

/// The result-builder DSL is sugar over the same `SQLSelect` AST the parser
/// produces, so every builder query must return exactly what the equivalent SQL
/// string returns. Each test runs both and asserts row-for-row equality.
struct SQLDSLTests {
    private func makeDB(_ dir: TempDir) throws -> Database {
        let db = try Database.open(at: dir.file("dsl.adsql"))
        try db.prepare(
            "CREATE TABLE docs(id INTEGER PRIMARY KEY, title TEXT, score REAL, kind TEXT)"
        )
        .run()
        try db.prepare(
            """
            INSERT INTO docs(id, title, score, kind) VALUES
              (1, 'alpha', 1.5, 'x'), (2, 'bravo', 3.0, 'y'),
              (3, 'charlie', 2.0, 'x'), (4, 'delta', 5.0, 'y'), (5, 'echo', 2.0, 'x')
            """
        )
        .run()
        return db
    }

    private func assertEqual(
        _ dsl: [SQLRow], _ sql: [SQLRow], _ comment: Comment? = nil
    ) {
        #expect(dsl.map(\.values) == sql.map(\.values), comment ?? "")
    }

    @Test func whereOrderLimitProxyForm() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }

        let dsl = try Query {
            Select("id", "title")
            From("docs")
            Where { $0.score > 2.0 }
            OrderBy("score", .descending)
            Limit(2)
        }
        .all(on: db)
        let sql =
            try db.prepare(
                "SELECT id, title FROM docs WHERE score > 2.0 ORDER BY score DESC LIMIT 2"
            )
            .all()
        assertEqual(dsl, sql)
    }

    @Test func selectStarMatchesSQL() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }

        let dsl = try Query {
            Select.all
            From("docs")
            OrderBy("id")
        }
        .all(on: db)
        let sql = try db.prepare("SELECT * FROM docs ORDER BY id").all()
        assertEqual(dsl, sql)
    }

    @Test func defaultSelectIsStar() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }

        let dsl = try Query {
            From("docs")
            OrderBy("id")
        }
        .all(on: db)
        let sql = try db.prepare("SELECT * FROM docs ORDER BY id").all()
        assertEqual(dsl, sql)
    }

    @Test func distinctAndConjunction() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }

        let dsl = try Query {
            Distinct()
            Select("kind")
            From("docs")
            Where { $0.score >= 2.0 && $0.kind == "x" }
            OrderBy("kind")
        }
        .all(on: db)
        let sql =
            try db.prepare(
                "SELECT DISTINCT kind FROM docs WHERE score >= 2.0 AND kind = 'x' ORDER BY kind"
            )
            .all()
        assertEqual(dsl, sql)
    }

    @Test func disjunctionLikeAndIn() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }

        let dsl = try Query {
            Select("id")
            From("docs")
            Where { $0.title.like("a%") || $0.id.in([2, 4]) }
            OrderBy("id")
        }
        .all(on: db)
        let sql =
            try db.prepare(
                "SELECT id FROM docs WHERE title LIKE 'a%' OR id IN (2, 4) ORDER BY id"
            )
            .all()
        assertEqual(dsl, sql)
    }

    @Test func offsetAndExplicitColumns() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }

        let dsl = try Query {
            Select(Column("title"))
            From("docs")
            OrderBy(Column("id"))
            Limit(2)
            Offset(2)
        }
        .all(on: db)
        let sql = try db.prepare("SELECT title FROM docs ORDER BY id LIMIT 2 OFFSET 2").all()
        assertEqual(dsl, sql)
    }

    @Test func innerJoinMatchesSQL() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("join.adsql"))
        defer { db.close() }
        try db.prepare("CREATE TABLE a(id INTEGER PRIMARY KEY, label TEXT)").run()
        try db.prepare("CREATE TABLE b(id INTEGER PRIMARY KEY, aid INTEGER, note TEXT)").run()
        try db.prepare("INSERT INTO a(id, label) VALUES (1, 'one'), (2, 'two')").run()
        try db.prepare("INSERT INTO b(id, aid, note) VALUES (10, 1, 'x'), (11, 2, 'y'), (12, 1, 'z')").run()

        let dsl = try Query {
            Select(Column("a", "label"), Column("b", "note"))
            From("a")
            Join("b", on: Column("b", "aid") == Column("a", "id"))
            OrderBy(Column("b", "id"))
        }
        .all(on: db)
        let sql =
            try db.prepare(
                "SELECT a.label, b.note FROM a JOIN b ON b.aid = a.id ORDER BY b.id"
            )
            .all()
        assertEqual(dsl, sql)
    }

    @Test func inlineFetchConvenience() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }

        let dsl = try db.fetch {
            Select("id")
            From("docs")
            Where { $0.kind == "y" }
            OrderBy("id")
        }
        let sql = try db.prepare("SELECT id FROM docs WHERE kind = 'y' ORDER BY id").all()
        assertEqual(dsl, sql)
    }

    @Test func firstReturnsLeadingRow() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }

        let row = try Query {
            Select("title")
            From("docs")
            OrderBy("score", .descending)
        }
        .first(on: db)
        #expect(row?.values.first == .text("delta"))
    }
}
