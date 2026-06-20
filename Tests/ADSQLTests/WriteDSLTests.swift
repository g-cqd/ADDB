import ADSQLModel
import Testing

@_spi(ADDBEngine) @testable import ADDBCore
@_spi(ADDBEngine) @testable import ADDBExec
@testable import ADDBTestSupport
@testable import ADSQL

/// The write-side builders lower to the same `SQLInsert`/`SQLUpdate`/`SQLDelete`
/// AST the parser produces, so each builder must have the same effect as the
/// equivalent SQL string.
struct WriteDSLTests {
    private func makeDB(_ dir: TempDir) throws -> Database {
        let db = try Database.open(at: dir.file("writedsl.adsql"))
        try db.prepare("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT, score REAL)").run()
        return db
    }

    private func rows(_ db: Database) throws -> [[Value]] {
        try db.prepare("SELECT id, name, score FROM users ORDER BY id").all().map(\.values)
    }

    @Test func insertSingleAndMultiRow() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }

        let result = try Insert(into: "users", columns: ["id", "name", "score"], values: [1, "Ada", 9.5])
            .run(on: db)
        #expect(result.changes == 1)
        try Insert(into: "users", columns: ["id", "name", "score"], rows: [[2, "Bo", 3.0], [3, "Cy", 4.0]])
            .run(on: db)

        #expect(
            try rows(db) == [
                [.integer(1), .text("Ada"), .real(9.5)],
                [.integer(2), .text("Bo"), .real(3.0)],
                [.integer(3), .text("Cy"), .real(4.0)]
            ])
    }

    @Test func insertOrIgnoreSkipsConflict() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }

        try Insert(into: "users", columns: ["id", "name", "score"], values: [1, "Ada", 1.0]).run(on: db)
        // A conflicting INSERT OR IGNORE leaves the original row and does not throw.
        try Insert(into: "users", columns: ["id", "name", "score"], values: [1, "Eve", 2.0])
            .orIgnore().run(on: db)
        #expect(try rows(db) == [[.integer(1), .text("Ada"), .real(1.0)]])

        // OR REPLACE overwrites it.
        try Insert(into: "users", columns: ["id", "name", "score"], values: [1, "Eve", 2.0])
            .orReplace().run(on: db)
        #expect(try rows(db) == [[.integer(1), .text("Eve"), .real(2.0)]])
    }

    @Test func updateSetsWhere() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }
        try Insert(into: "users", columns: ["id", "name", "score"], rows: [[1, "Ada", 1.0], [2, "Bo", 2.0]])
            .run(on: db)

        let result = try Update("users").set("name", to: "Adabelle").set("score", to: 9.0)
            .where { $0.id == 1 }.run(on: db)
        #expect(result.changes == 1)
        #expect(
            try rows(db) == [
                [.integer(1), .text("Adabelle"), .real(9.0)],
                [.integer(2), .text("Bo"), .real(2.0)]
            ])
    }

    @Test func deleteWhere() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir)
        defer { db.close() }
        try Insert(
            into: "users", columns: ["id", "name", "score"], rows: [[1, "A", 1.0], [2, "B", 2.0], [3, "C", 3.0]]
        )
        .run(on: db)

        let result = try Delete(from: "users").where { $0.id == 2 }.run(on: db)
        #expect(result.changes == 1)
        #expect(try rows(db).map { $0[0] } == [.integer(1), .integer(3)])
    }
}
