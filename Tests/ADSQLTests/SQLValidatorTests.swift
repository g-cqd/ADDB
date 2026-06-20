import ADDBMacros
import ADSQLModel
import Testing

@_spi(ADDBEngine) @testable import ADDBCore
@_spi(ADDBEngine) @testable import ADDBExec
@testable import ADDBTestSupport
@testable import ADSQL

/// `Doc` mirrors the `docs` fixture, so `@Table` synthesis + `Query.all(on:as:)`
/// decode a SELECT result into typed values.
@Table("docs")
struct Doc {
    let id: Int64
    let title: String
    let score: Double
    let kind: String
}

@Suite("SQL DSL — validation + typed rows")
struct SQLValidatorTests {
    private func makeDB(_ dir: TempDir) throws -> Database {
        let db = try Database.open(at: dir.file("validator.adsql"))
        try db.prepare("CREATE TABLE docs(id INTEGER PRIMARY KEY, title TEXT, score REAL, kind TEXT)").run()
        try db.prepare(
            "INSERT INTO docs(id, title, score, kind) VALUES (1,'alpha',1.5,'x'),(2,'bravo',3.0,'y')"
        )
        .run()
        return db
    }

    // MARK: - validate(against:)

    @Test func validQueryValidates() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }
        try Query {
            Select("id", "title")
            From("docs")
            Where { $0.score > 1.0 }
        }
        .validate(against: db)
    }

    @Test func unknownTableFailsValidation() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }
        #expect(throws: SQLBuildError.self) {
            try Query {
                Select.all
                From("ghosts")
            }
            .validate(against: db)
        }
    }

    // MARK: - Typed rows via @Table

    @Test func allDecodesTypedRows() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }
        let docs = try Query {
            Select("id", "title", "score", "kind")
            From("docs")
            OrderBy("id")
        }
        .all(on: db, as: Doc.self)
        #expect(docs.count == 2)
        #expect(docs[0].id == 1)
        #expect(docs[0].title == "alpha")
        #expect(docs[0].score == 1.5)
        #expect(docs[1].kind == "y")
    }

    @Test func firstDecodesTypedRow() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }
        let doc = try Query {
            Select("id", "title", "score", "kind")
            From("docs")
            OrderBy("id")
        }
        .first(on: db, as: Doc.self)
        #expect(doc?.id == 1)
        #expect(doc?.title == "alpha")
    }

    @Test func fetchTypedConvenience() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }
        let docs = try db.fetch(Doc.self) {
            Select("id", "title", "score", "kind")
            From("docs")
            Where { $0.kind == "x" }
        }
        #expect(docs.count == 1)
        #expect(docs[0].id == 1)
    }
}
