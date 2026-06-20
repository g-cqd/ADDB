import ADSQLModel
import Testing

@_spi(ADDBEngine) @testable import ADDBCore
@_spi(ADDBEngine) @testable import ADDBExec
@testable import ADDBTestSupport
@testable import ADSQL

/// Deterministic `datetime('now')` through the public SQL API: a database opened with
/// `DatabaseOptions(now:)` resolves `datetime('now')` against the pinned clock, with no
/// real-time read. The `now` provider threads `Statement → SQLParameters → SQLEvalEnv →
/// CivilTime`. The live clock stays the default, so untouched databases are unchanged.
struct DatetimeClockTests {
    @Test
    func `datetime('now') in a SELECT resolves against the injected clock`() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(
            at: dir.file("dt.adsql"), options: DatabaseOptions(now: { 1_609_459_200 }))
        defer { db.close() }
        try db.prepare("CREATE TABLE one(x INTEGER)").run()
        try db.prepare("INSERT INTO one(x) VALUES (1)").run()
        let rows = try db.prepare("SELECT datetime('now') FROM one").all()
        #expect(rows.count == 1)
        #expect(rows[0][0] == .text("2021-01-01 00:00:00"))
    }

    @Test
    func `a DEFAULT (datetime('now')) column is pinned to the injected clock`() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(
            at: dir.file("dt2.adsql"), options: DatabaseOptions(now: { 0 }))
        defer { db.close() }
        try db.prepare("CREATE TABLE stamped(k INTEGER, at TEXT DEFAULT (datetime('now')))").run()
        try db.prepare("INSERT INTO stamped(k) VALUES (1)").run()
        let rows = try db.prepare("SELECT at FROM stamped").all()
        #expect(rows.count == 1)
        #expect(rows[0][0] == .text("1970-01-01 00:00:00"))
    }
}
