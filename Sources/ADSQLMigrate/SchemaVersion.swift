// Engine types (`Database`, `DBError`) appear only in this file's internal
// helpers, so the SPI import stays non-public (no public surface uses it).
@_spi(ADDBEngine) import ADDBCore
import ADDBExec
import ADSQL
public import ADSQLModel

/// The migration cursor: a single-row `schema_version` table whose `version`
/// column records the highest migration applied to the database. A fresh
/// database (no table yet) is treated as version ``baseline`` (0).
///
/// The table is deliberately tiny and append-free: every bump is an UPDATE of
/// the one row, performed inside the same transaction as the migration body so
/// the cursor advances if and only if the body commits.
public enum SchemaVersion {
    /// The version a database is at before any migration has run. The first
    /// real migration is version 1 (see ``MigrationError/nonPositiveVersion``).
    public static let baseline = 0

    /// The cursor table's name. Mirrors SQLite's convention of a lower-snake
    /// metadata table; the name is fixed (not configurable) so two builds of an
    /// app always agree on where the cursor lives.
    public static let tableName = "schema_version"

    /// DDL creating the cursor table if absent. `version` is the migration
    /// pointer; `applied_at` records the epoch-seconds wall-clock of the last
    /// applied migration (NULL for the bootstrap row). Run once at open via
    /// ``ensureExists(_:)``.
    static let createTableSQL = """
        CREATE TABLE IF NOT EXISTS \(tableName)(
          version INTEGER NOT NULL,
          applied_at INTEGER)
        """

    /// Seeds the single baseline row when the table was just created empty.
    static let seedBaselineSQL =
        "INSERT INTO \(tableName)(version, applied_at) VALUES(\(baseline), NULL)"

    /// Reads the single row's version.
    static let readVersionSQL = "SELECT version FROM \(tableName) LIMIT 1"

    /// Bumps the cursor in place. ADSQL binds bare `?` markers by appearance
    /// order (it rejects `?NNN`), so the first `?` = new version and the second
    /// = applied-at epoch seconds, matching the positional array the migrator
    /// passes. Updates every row so a (corrupt) multi-row table still collapses
    /// to one logical cursor value; under the invariant there is exactly one row.
    static let bumpSQL = "UPDATE \(tableName) SET version = ?, applied_at = ?"

    /// Creates the cursor table if missing and guarantees the single baseline
    /// row exists, returning the current version. Idempotent: safe to call at
    /// every open. Runs in one write transaction so a fresh database lands the
    /// table + seed row atomically.
    ///
    /// - Returns: the current cursor version (``baseline`` for a fresh database).
    static func ensureExists(_ database: Database) throws(DBError) -> Int {
        // Create + seed atomically. CREATE TABLE IF NOT EXISTS is a no-op on an
        // existing table; the seed only fires when we just created it (guarded by
        // the row count read after creation, inside the same txn is not possible
        // because SQLTransaction forbids SELECT — so we seed conditionally below).
        try database.transaction { (txn) throws(DBError) in
            try txn.run(createTableSQL)
        }
        // Read post-create; seed if empty (first ever open). The read is a SELECT,
        // which must run outside the transaction block (that block is write-only).
        if try currentVersion(database) == nil {
            try database.transaction { (txn) throws(DBError) in
                try txn.run(seedBaselineSQL)
            }
        }
        // The row now exists; read the authoritative value.
        return try currentVersion(database) ?? baseline
    }

    /// The recorded version, or nil when the table has no row yet (a freshly
    /// created, not-yet-seeded table). Reads outside any transaction.
    static func currentVersion(_ database: Database) throws(DBError) -> Int? {
        guard let row = try database.prepare(readVersionSQL).get() else { return nil }
        guard case .integer(let version) = row[0] else { return nil }
        return Int(version)
    }
}
