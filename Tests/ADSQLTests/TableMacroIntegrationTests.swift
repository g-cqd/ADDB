import ADDBMacros
import ADSQLModel
import Testing

@_spi(ADDBEngine) @testable import ADDBCore
@_spi(ADDBEngine) @testable import ADDBExec
@testable import ADDBTestSupport
@testable import ADSQL

/// Exercises the `@Table`-synthesized `TableRow` conformance end to end: the
/// generated `tableDefinition` creates the table, and the generated `init(row:)`
/// decodes a `SELECT` result back into typed values. This proves the macro's
/// output compiles and round-trips (more robust than asserting expanded source).
@Table("users")
struct MacroUser {
    let id: Int64
    let name: String
    let nickname: String?
    let score: Double
    let active: Bool
    let avatar: [UInt8]?
}

struct TableMacroIntegrationTests {
    @Test func definitionMirrorsStoredProperties() {
        let definition = MacroUser.tableDefinition
        #expect(definition.name == "users")
        #expect(definition.columns.map(\.name) == ["id", "name", "nickname", "score", "active", "avatar"])
        #expect(definition.columns.map(\.type) == [.integer, .text, .text, .real, .integer, .blob])
        #expect(definition.columns.map(\.notNull) == [true, true, false, true, true, false])
    }

    @Test func rowInitDecodesSelectResults() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("tablemacro.adsql"))
        defer { db.close() }

        try db.writeSync { (txn) throws(DBError) in try txn.createTable(MacroUser.tableDefinition) }
        try db.prepare(
            "INSERT INTO users(id, name, nickname, score, active, avatar) VALUES (1, 'Ada', NULL, 9.5, 1, NULL)"
        )
        .run()
        try db.prepare(
            "INSERT INTO users(id, name, nickname, score, active, avatar) VALUES (2, 'Bob', 'bobby', 3.0, 0, x'00ff')"
        )
        .run()

        let rows =
            try db.prepare(
                "SELECT id, name, nickname, score, active, avatar FROM users ORDER BY id"
            )
            .all()
        let users = try rows.map(MacroUser.init(row:))

        #expect(users.count == 2)
        #expect(users[0].id == 1)
        #expect(users[0].name == "Ada")
        #expect(users[0].nickname == nil)
        #expect(users[0].score == 9.5)
        #expect(users[0].active == true)
        #expect(users[0].avatar == nil)
        #expect(users[1].nickname == "bobby")
        #expect(users[1].active == false)
        #expect(users[1].avatar == [0x00, 0xFF])
    }

    @Test func rowInitThrowsOnStorageClassMismatch() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("tablemacro-mismatch.adsql"))
        defer { db.close() }
        // A row whose first column is TEXT, not the INTEGER `id` expects.
        let row = SQLRow(
            header: SQLColumnHeader(["id", "name", "nickname", "score", "active", "avatar"]),
            values: [.text("nope"), .text("x"), .null, .real(1), .integer(1), .null])
        #expect(throws: DBError.self) { _ = try MacroUser(row: row) }
    }
}
