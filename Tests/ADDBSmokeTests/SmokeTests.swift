import ADDB
import ADSQLModel
import Foundation
import Testing

/// End-to-end executor smoke tests over the public `ADDB` façade, proving the
/// post-inversion pipeline (`SQLParser` in ADSQL → bind/plan/execute in ADDBExec
/// → storage in ADDBCore) runs correctly through one `import ADDB`. These are a
/// fast guardrail for the big-bang inversion ahead of re-homing the full
/// `ADSQLTests` integration suite into this package.
struct ADDBSmokeTests {
    /// Opens a fresh file-backed database at a unique temp path and removes it after.
    private func withTempDB(_ body: (Database) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("addb-smoke-\(UUID().uuidString).addb").path
        let db = try Database.open(at: path)
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        try body(db)
    }

    @Test
    func `CREATE / INSERT / SELECT round-trips rows in order`() throws {
        try withTempDB { db in
            _ = try db.prepare("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT)").run()
            _ = try db.prepare("INSERT INTO users(id, name) VALUES (1, 'Ada'), (2, 'Bo')").run()
            let rows = try db.prepare("SELECT id, name FROM users ORDER BY id").all()
            #expect(rows.count == 2)
            #expect(rows[0]["id"] == Value.integer(1))
            #expect(rows[0]["name"] == Value.text("Ada"))
            #expect(rows[1]["name"] == Value.text("Bo"))
        }
    }

    @Test
    func `WHERE + parameter binding filters rows`() throws {
        try withTempDB { db in
            _ = try db.prepare("CREATE TABLE t(a INTEGER, b TEXT)").run()
            _ = try db.prepare("INSERT INTO t(a, b) VALUES (1,'x'),(2,'y'),(3,'z')").run()
            let rows = try db.prepare("SELECT b FROM t WHERE a >= ? ORDER BY a").all(.integer(2))
            #expect(rows.map { $0[0] } == [Value.text("y"), Value.text("z")])
        }
    }

    @Test
    func `GROUP BY aggregate computes SUM per group`() throws {
        try withTempDB { db in
            _ = try db.prepare("CREATE TABLE t(a INTEGER, b INTEGER)").run()
            _ = try db.prepare("INSERT INTO t(a,b) VALUES (1,10),(1,20),(2,5)").run()
            let rows = try db.prepare("SELECT a, SUM(b) AS s FROM t GROUP BY a ORDER BY a").all()
            #expect(rows.count == 2)
            #expect(rows[0]["s"] == Value.integer(30))
            #expect(rows[1]["s"] == Value.integer(5))
        }
    }

    @Test
    func `INNER JOIN matches across two tables`() throws {
        try withTempDB { db in
            _ = try db.prepare("CREATE TABLE u(id INTEGER PRIMARY KEY, name TEXT)").run()
            _ = try db.prepare("CREATE TABLE o(uid INTEGER, item TEXT)").run()
            _ = try db.prepare("INSERT INTO u(id,name) VALUES (1,'Ada'),(2,'Bo')").run()
            _ = try db.prepare("INSERT INTO o(uid,item) VALUES (1,'book'),(1,'pen'),(2,'lamp')").run()
            let rows =
                try db.prepare(
                    "SELECT u.name, o.item FROM o JOIN u ON u.id = o.uid ORDER BY u.name, o.item"
                )
                .all()
            #expect(rows.count == 3)
            #expect(rows[0]["name"] == Value.text("Ada"))
            #expect(rows[0]["item"] == Value.text("book"))
            #expect(rows[2]["name"] == Value.text("Bo"))
        }
    }

    @Test
    func `a malformed statement throws a typed DBError, never traps`() throws {
        try withTempDB { db in
            #expect(throws: DBError.self) {
                _ = try db.prepare("SELECT FROM WHERE").all()
            }
        }
    }
}
