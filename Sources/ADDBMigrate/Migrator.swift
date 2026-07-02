@_spi(ADDBEngine) public import ADDBCore
import ADDBExec
import ADSQL
import ADSQLModel

/// Applies pending ``Migration``s to a `Database` in ascending version order,
/// using ADDB's MVCC commit as the atomic boundary.
///
/// Each migration runs inside ONE write transaction that also bumps
/// ``SchemaVersion``. Because an MVCC commit is all-or-nothing, a crash or a
/// throwing body leaves the database either fully at the old version or fully at
/// the new one — never half-migrated. This is the whole reason the engine omits
/// `ALTER TABLE`: recreate-and-copy under a single transaction is strictly
/// stronger than mutating column layout in the kernel.
///
/// Forward-only by default: a database whose recorded version exceeds every
/// registered migration is refused rather than downgraded (see
/// ``MigrationError/databaseAheadOfMigrations``).
public struct Migrator: Sendable {
    /// Registered migrations, sorted ascending by version. Immutable after init.
    public let migrations: [Migration]

    /// When true (the default), a database recorded ahead of the latest known
    /// migration is an error. Set false only for tooling that knowingly opens a
    /// newer database read-shaped.
    public let forwardOnly: Bool

    /// Builds a migrator from an unordered set of migrations.
    ///
    /// - Throws: ``MigrationError/duplicateVersion(_:)`` if two share a version,
    ///   or ``MigrationError/nonPositiveVersion(_:)`` if any targets version < 1.
    public init(migrations: [Migration], forwardOnly: Bool = true) throws(MigrationError) {
        var seen = Set<Int>()
        for migration in migrations {
            guard migration.version >= 1 else {
                throw MigrationError.nonPositiveVersion(migration.version)
            }
            guard seen.insert(migration.version).inserted else {
                throw MigrationError.duplicateVersion(migration.version)
            }
        }
        self.migrations = migrations.sorted { $0.version < $1.version }
        self.forwardOnly = forwardOnly
    }

    /// The highest version this migrator can bring a database to (``baseline``
    /// when it holds no migrations).
    public var latestVersion: Int {
        migrations.last?.version ?? SchemaVersion.baseline
    }

    /// The outcome of an ``migrate(_:)`` run.
    public struct Outcome: Equatable, Sendable {
        /// The cursor version before any migration ran.
        public let startingVersion: Int
        /// The cursor version after the run (== `startingVersion` for a no-op).
        public let finalVersion: Int
        /// The versions applied this run, ascending (empty for a no-op).
        public let appliedVersions: [Int]

        /// Whether any migration ran.
        public var didMigrate: Bool { !appliedVersions.isEmpty }
    }

    /// Reads `schema_version` (creating it at ``baseline`` on a fresh database),
    /// then applies every registered migration whose version exceeds the recorded
    /// one, ascending. Each runs in its own transaction that also advances the
    /// cursor. Returns without doing work when already at (or above, when not
    /// forward-only) the target.
    ///
    /// - Parameters:
    ///   - database: an open read-write `Database`.
    ///   - now: epoch-seconds source for `applied_at` stamps (defaults to the
    ///     database's configured clock).
    /// - Returns: an ``Outcome`` recording the starting and final cursor versions
    ///   and the versions applied this run (empty for a no-op).
    /// - Throws: ``MigrationError`` for orchestration faults, or the engine's
    ///   `DBError` (unchanged) when a migration body or the cursor write fails —
    ///   in which case that migration's transaction rolled back and the cursor
    ///   still reads the prior version.
    @discardableResult
    public func migrate(
        _ database: Database, now: (@Sendable () -> Int64)? = nil
    ) throws -> Outcome {
        let clock = now ?? database.options.now
        let startingVersion = try SchemaVersion.ensureExists(database)

        if startingVersion > latestVersion {
            if forwardOnly {
                throw MigrationError.databaseAheadOfMigrations(
                    database: startingVersion, latestKnown: latestVersion)
            }
            // Not forward-only: a newer database is left untouched.
            return Outcome(
                startingVersion: startingVersion, finalVersion: startingVersion,
                appliedVersions: [])
        }

        var applied: [Int] = []
        var currentVersion = startingVersion
        for migration in migrations where migration.version > startingVersion {
            try apply(migration, to: database, appliedAt: clock())
            currentVersion = migration.version
            applied.append(migration.version)
        }

        return Outcome(
            startingVersion: startingVersion, finalVersion: currentVersion,
            appliedVersions: applied)
    }

    /// Runs one migration body and the cursor bump inside a single write
    /// transaction. The throw type is `any Error` because the body uses
    /// `throws(DBError)` while the orchestration around it is `DBError`-typed
    /// too; both surface unchanged so the caller can distinguish them.
    private func apply(
        _ migration: Migration, to database: Database, appliedAt: Int64
    ) throws {
        try database.transaction { (txn) throws(DBError) in
            // The body's work and the version bump share this one transaction, so
            // they commit together or roll back together (MVCC all-or-nothing).
            let context = MigrationContext(txn: txn)
            try migration.body(context)
            try txn.run(
                SchemaVersion.bumpSQL,
                SQLParameters(positional: [.integer(Int64(migration.version)), .integer(appliedAt)]))
        }
    }
}
