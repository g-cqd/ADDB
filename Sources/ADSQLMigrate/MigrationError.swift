public import ADSQLModel

/// Errors raised by the schema migrator, distinct from the engine's `DBError`
/// so a migration-orchestration fault (a duplicate version, a backward jump)
/// is never confused with a SQL/storage fault from a migration body.
///
/// Engine faults thrown by a migration body (`DBError`) propagate unchanged —
/// the migrator never swallows them; it only adds the orchestration layer on
/// top.
public enum MigrationError: Error, Equatable, Sendable {
    /// Two registered migrations share the same target version.
    case duplicateVersion(Int)

    /// A migration targets version <= 0. Version 0 is the reserved "empty"
    /// baseline that every fresh database starts at, so the first real
    /// migration must be version >= 1.
    case nonPositiveVersion(Int)

    /// The recorded `schema_version` is ahead of every registered migration and
    /// `forwardOnly` is in effect (the default). The database was written by a
    /// newer build of the app; refusing to run protects it from a downgrade.
    case databaseAheadOfMigrations(database: Int, latestKnown: Int)

    /// A recreate-and-copy plan named a column shared between the source and
    /// destination column lists with mismatched arity (the `INSERT … SELECT`
    /// would fail the engine's column-count check). Caught before opening the
    /// transaction so the message names the offending table.
    case columnMappingArityMismatch(table: String, destinationCount: Int, sourceCount: Int)

    /// A recreate-and-copy plan supplied an empty destination column list, which
    /// can never preserve a rowid.
    case emptyColumnMapping(table: String)

    public var message: String {
        switch self {
            case .duplicateVersion(let version):
                return "duplicate migration version \(version)"
            case .nonPositiveVersion(let version):
                return "migration version must be >= 1 (got \(version)); 0 is the empty baseline"
            case .databaseAheadOfMigrations(let database, let latestKnown):
                return
                    "database schema_version \(database) is ahead of the latest known migration "
                    + "\(latestKnown); a forward-only migrator will not downgrade it"
            case .columnMappingArityMismatch(let table, let destinationCount, let sourceCount):
                return
                    "recreate-and-copy of \(table): destination column count \(destinationCount) "
                    + "!= source expression count \(sourceCount)"
            case .emptyColumnMapping(let table):
                return "recreate-and-copy of \(table): empty column mapping cannot preserve rowid"
        }
    }
}
