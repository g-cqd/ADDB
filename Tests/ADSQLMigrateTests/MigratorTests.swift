@_spi(ADDBEngine) import ADDBCore
import ADSQL
import ADSQLMigrate
import ADSQLModel
import Testing

@_spi(ADDBEngine) @testable import ADDBExec

/// The recreate-and-copy schema migrator over ADSQL's public Database/Statement
/// API. Each test opens a throwaway on-disk database (the engine has no
/// `:memory:` mode) and exercises one slice of the contract: the `schema_version`
/// cursor, additive migrations, the column-shape recreate-and-copy path
/// (rowid + FK preservation, FTS-rebuild-once), no-op re-runs, and
/// transactional rollback on a throwing body.
@Suite("Migrate")
struct MigratorTests {
    // MARK: - schema_version cursor

    @Test("a fresh database reports the baseline version after ensureExists")
    func freshDatabaseStartsAtBaseline() throws {
        let temp = try TempDatabase()
        defer { temp.teardown() }
        let db = temp.db

        // An empty migrator does no work but still creates + seeds the cursor.
        let migrator = try Migrator(migrations: [])
        let outcome = try migrator.migrate(db)

        #expect(outcome.startingVersion == SchemaVersion.baseline)
        #expect(outcome.finalVersion == SchemaVersion.baseline)
        #expect(!outcome.didMigrate)

        // The cursor table now exists with exactly one row at the baseline.
        let version = try db.scalarInt("SELECT version FROM schema_version")
        #expect(version == Int64(SchemaVersion.baseline))
        let rowCount = try db.scalarInt("SELECT COUNT(*) FROM schema_version")
        #expect(rowCount == 1)
    }

    // MARK: - additive migration

    @Test("an additive CREATE TABLE migration advances the cursor to 1")
    func additiveMigrationCreatesTableAndBumpsCursor() throws {
        let temp = try TempDatabase()
        defer { temp.teardown() }
        let db = temp.db

        let addTags = Migration(version: 1, name: "add tags table") { ctx throws(DBError) in
            try ctx.run("CREATE TABLE tag(id INTEGER PRIMARY KEY, label TEXT NOT NULL)")
            try ctx.run("CREATE INDEX tag_label ON tag(label)")
        }
        let migrator = try Migrator(migrations: [addTags])
        let outcome = try migrator.migrate(db)

        #expect(outcome.startingVersion == 0)
        #expect(outcome.finalVersion == 1)
        #expect(outcome.appliedVersions == [1])
        #expect(outcome.didMigrate)

        // The cursor advanced and the new object is usable in the same database.
        #expect(try db.scalarInt("SELECT version FROM schema_version") == 1)
        try db.prepare("INSERT INTO tag(id, label) VALUES(1, 'swift')").run()
        #expect(try db.scalarInt("SELECT COUNT(*) FROM tag") == 1)

        // applied_at recorded the pinned clock.
        #expect(try db.scalarInt("SELECT applied_at FROM schema_version") == 1_700_000_000)
    }

    @Test("two additive migrations apply in ascending order, cursor lands on the last")
    func multipleAdditiveMigrationsApplyInOrder() throws {
        let temp = try TempDatabase()
        defer { temp.teardown() }
        let db = temp.db

        let v1 = Migration(version: 1) { ctx throws(DBError) in
            try ctx.run("CREATE TABLE a(id INTEGER PRIMARY KEY)")
        }
        let v2 = Migration(version: 2) { ctx throws(DBError) in
            try ctx.run("CREATE TABLE b(id INTEGER PRIMARY KEY)")
        }
        // Registered out of order; the migrator must sort them.
        let migrator = try Migrator(migrations: [v2, v1])
        let outcome = try migrator.migrate(db)

        #expect(outcome.appliedVersions == [1, 2])
        #expect(outcome.finalVersion == 2)
        #expect(try db.scalarInt("SELECT version FROM schema_version") == 2)
        // Both tables exist.
        #expect(try db.scalarInt("SELECT COUNT(*) FROM a") == 0)
        #expect(try db.scalarInt("SELECT COUNT(*) FROM b") == 0)
    }

    // MARK: - no-op re-runs

    @Test("re-running a migrator already at the target version does nothing")
    func reRunAtTargetIsNoOp() throws {
        let temp = try TempDatabase()
        defer { temp.teardown() }
        let db = temp.db

        let v1 = Migration(version: 1) { ctx throws(DBError) in
            try ctx.run("CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)")
            try ctx.run("INSERT INTO t(id, v) VALUES(1, 42)")
        }
        let migrator = try Migrator(migrations: [v1])

        let first = try migrator.migrate(db)
        #expect(first.appliedVersions == [1])

        // A second run sees the cursor already at 1: no migration body re-executes
        // (the seed row from the first run is untouched, proving v1's body did not
        // run again — a re-run would throw on the duplicate INSERT/CREATE).
        let second = try migrator.migrate(db)
        #expect(second.startingVersion == 1)
        #expect(second.finalVersion == 1)
        #expect(second.appliedVersions == [])
        #expect(!second.didMigrate)
        #expect(try db.scalarInt("SELECT COUNT(*) FROM t") == 1)
        #expect(try db.scalarInt("SELECT v FROM t WHERE id = 1") == 42)
    }

    @Test("a partially-migrated database resumes from its recorded version")
    func partialDatabaseResumes() throws {
        let temp = try TempDatabase()
        defer { temp.teardown() }
        let db = temp.db

        let v1 = Migration(version: 1) { ctx throws(DBError) in
            try ctx.run("CREATE TABLE a(id INTEGER PRIMARY KEY)")
        }
        // Bring the database to v1 only.
        _ = try Migrator(migrations: [v1]).migrate(db)
        #expect(try db.scalarInt("SELECT version FROM schema_version") == 1)

        // Now a migrator that also knows v2 applies only the missing step.
        let v2 = Migration(version: 2) { ctx throws(DBError) in
            try ctx.run("CREATE TABLE b(id INTEGER PRIMARY KEY)")
        }
        let outcome = try Migrator(migrations: [v1, v2]).migrate(db)
        #expect(outcome.startingVersion == 1)
        #expect(outcome.appliedVersions == [2])
        #expect(try db.scalarInt("SELECT version FROM schema_version") == 2)
    }

    // MARK: - rollback / atomicity

    @Test("a throwing migration body rolls back: cursor and schema stay at the prior version")
    func throwingBodyRollsBackAtomically() throws {
        let temp = try TempDatabase()
        defer { temp.teardown() }
        let db = temp.db

        // v1 succeeds; v2 creates a table and THEN throws, so the whole v2
        // transaction (including the table it created and the cursor bump) must
        // roll back. MVCC commit is all-or-nothing — this is the design's point.
        let v1 = Migration(version: 1) { ctx throws(DBError) in
            try ctx.run("CREATE TABLE keep(id INTEGER PRIMARY KEY)")
        }
        let v2 = Migration(version: 2) { ctx throws(DBError) in
            try ctx.run("CREATE TABLE doomed(id INTEGER PRIMARY KEY)")
            // A bad statement inside the body throws a real DBError, aborting the txn.
            try ctx.run("INSERT INTO no_such_table(id) VALUES(1)")
        }
        let migrator = try Migrator(migrations: [v1, v2])

        #expect(throws: (any Error).self) {
            try migrator.migrate(db)
        }

        // v1 committed (cursor at 1, its table present); v2 rolled back entirely.
        #expect(try db.scalarInt("SELECT version FROM schema_version") == 1)
        #expect(try db.scalarInt("SELECT COUNT(*) FROM keep") == 0)
        // The doomed table from v2 must NOT exist — the txn that created it aborted.
        #expect(throws: DBError.self) {
            try db.prepare("SELECT COUNT(*) FROM doomed").get()
        }

        // Re-running with a fixed v2 now applies cleanly from where it stopped.
        let fixedV2 = Migration(version: 2) { ctx throws(DBError) in
            try ctx.run("CREATE TABLE doomed(id INTEGER PRIMARY KEY)")
        }
        let outcome = try Migrator(migrations: [v1, fixedV2]).migrate(db)
        #expect(outcome.startingVersion == 1)
        #expect(outcome.appliedVersions == [2])
        #expect(try db.scalarInt("SELECT version FROM schema_version") == 2)
    }

    // MARK: - forward-only guard & validation

    @Test("a forward-only migrator refuses a database ahead of its latest migration")
    func forwardOnlyRefusesNewerDatabase() throws {
        let temp = try TempDatabase()
        defer { temp.teardown() }
        let db = temp.db

        // Bring the database to v2.
        let v1 = Migration(version: 1) { ctx throws(DBError) in
            try ctx.run("CREATE TABLE a(id INTEGER PRIMARY KEY)")
        }
        let v2 = Migration(version: 2) { ctx throws(DBError) in
            try ctx.run("CREATE TABLE b(id INTEGER PRIMARY KEY)")
        }
        _ = try Migrator(migrations: [v1, v2]).migrate(db)

        // An older build (only knows v1) opening this v2 database is refused.
        let older = try Migrator(migrations: [v1])
        #expect(throws: MigrationError.self) {
            try older.migrate(db)
        }
        // The cursor is untouched by the refusal.
        #expect(try db.scalarInt("SELECT version FROM schema_version") == 2)

        // A non-forward-only migrator leaves the newer database alone (no throw).
        let lenient = try Migrator(migrations: [v1], forwardOnly: false)
        let outcome = try lenient.migrate(db)
        #expect(!outcome.didMigrate)
        #expect(outcome.finalVersion == 2)
    }

    @Test("the migrator init rejects duplicate and non-positive versions")
    func initValidatesVersions() throws {
        #expect(throws: MigrationError.duplicateVersion(2)) {
            try Migrator(migrations: [
                Migration(version: 2) { _ throws(DBError) in },
                Migration(version: 2) { _ throws(DBError) in }
            ])
        }
        #expect(throws: MigrationError.nonPositiveVersion(0)) {
            try Migrator(migrations: [Migration(version: 0) { _ throws(DBError) in }])
        }
    }
}
