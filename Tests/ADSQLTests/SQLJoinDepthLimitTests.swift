import ADSQLModel
import Testing

@_spi(ADDBEngine) @testable import ADDBCore
@_spi(ADDBEngine) @testable import ADDBExec
@testable import ADDBTestSupport
@testable import ADSQL

/// The nested-loop join driver recurses once per joined table, so an unbounded table count is a
/// stack-overflow / denial-of-service hazard. `SelectExecutor.maxJoinTables` caps it; these tests pin
/// that a join past the cap is rejected DETERMINISTICALLY (a `DBError`, never a crash) while a normal
/// multi-table join still runs.
@Suite("SQL join depth limit")
struct SQLJoinDepthLimitTests {
    private func makeDB(_ dir: TempDir, _ name: String) throws -> Database {
        let db = try Database.open(at: dir.file(name))
        try db.prepare("CREATE TABLE t(x INTEGER)").run()
        try db.prepare("INSERT INTO t(x) VALUES(1)").run()
        return db
    }

    private func selfJoin(aliases: Int) -> String {
        var sql = "SELECT COUNT(*) FROM t a0"
        for i in 1 ..< aliases { sql += " JOIN t a\(i) ON 1=1" }
        return sql
    }

    @Test func joinWiderThanCapIsRejectedNotCrashed() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir, "join-over-cap.adsql")
        defer { db.close() }
        // One table past the cap: must throw rather than recurse into a stack overflow.
        let sql = selfJoin(aliases: SelectExecutor.maxJoinTables + 1)
        #expect(throws: DBError.self) {
            _ = try db.prepare(sql).all()
        }
    }

    @Test func joinUnderCapStillRuns() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try makeDB(dir, "join-under-cap.adsql")
        defer { db.close() }
        // Eight aliases of a single-row table cross-joined → exactly one combined row.
        let rows = try db.prepare(selfJoin(aliases: 8)).all().map(\.values)
        #expect(rows == [[.integer(1)]])
    }
}
