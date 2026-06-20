@_spi(ADDBEngine) import ADDBCore
import ADSQL
import ADSQLModel
import Foundation

@_spi(ADDBEngine) @testable import ADDBExec

/// A throwaway on-disk database in a private temp directory, for the migrator
/// suite. `Database.open` needs a file path (the engine has no `:memory:` mode),
/// so each test opens one under a unique directory and tears it down on `close`.
///
/// Deliberately self-contained (a few `FileManager` calls) rather than reaching
/// for the dev-only `ADTestKit.TemporaryDirectory`, so `ADSQLMigrateTests` builds
/// without the `ADSQL_DEV` gate.
///
/// A plain value type: the one owned resource is the engine `Database` (a class
/// with its own `close()`), so ``teardown()`` is the single explicit cleanup,
/// called from a test's `defer`.
struct TempDatabase {
    let directory: String
    let path: String
    let db: Database

    /// Opens a fresh database. `now` pins the wall clock for deterministic
    /// `applied_at` stamps (defaults to a fixed instant rather than the live clock
    /// so two runs of a test agree).
    init(now: @escaping @Sendable () -> Int64 = { 1_700_000_000 }) throws {
        let base = FileManager.default.temporaryDirectory.path
        let unique = "adsqlmigrate-\(ProcessInfo.processInfo.processIdentifier)-\(UInt64.random(in: .min ... .max))"
        let directory = base + "/" + unique
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        let file = directory + "/test.adsql"
        self.directory = directory
        self.path = file
        self.db = try Database.open(at: file, options: DatabaseOptions(now: now))
    }

    /// Closes the handle and removes the temp directory. Call once per test.
    func teardown() {
        db.close()
        try? FileManager.default.removeItem(atPath: directory)
    }
}

extension Database {
    /// The single integer in a one-column, one-row result (or nil when empty).
    /// A reader sugar for the migrator tests, which assert on counts and rowids.
    func scalarInt(_ sql: String, _ parameters: Value...) throws(DBError) -> Int64? {
        guard let row = try prepare(sql).get(SQLParameters(positional: parameters)) else {
            return nil
        }
        guard case .integer(let value) = row[0] else { return nil }
        return value
    }

    /// Every value in a one-column result, in row order (integers only; non-integer
    /// cells map to nil so a mismatch surfaces loudly).
    func columnInts(_ sql: String) throws(DBError) -> [Int64?] {
        try prepare(sql).all()
            .map { row in
                if case .integer(let value) = row[0] { return value }
                return nil
            }
    }
}
