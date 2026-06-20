@_spi(ADDBEngine) import ADDBCore
public import ADDBExec
// `public` because `MigrationContext.run` returns ADSQL's `RunResult` in a public
// signature; the other ADSQLMigrate files import ADSQL plainly (internal use only).
import ADSQL
public import ADSQLModel

/// One schema migration: a target ``version`` and a ``body`` that performs the
/// DDL/DML carrying the database from `version - 1`'s shape to `version`'s.
///
/// The body runs inside a single write transaction that the ``Migrator`` also
/// uses to bump ``SchemaVersion``; an MVCC commit is all-or-nothing, so a crash
/// leaves the database either fully at the old version or fully at the new one.
/// Because the transaction is the durability boundary, the body must perform all
/// its work through the supplied ``MigrationContext`` (never by opening its own
/// transaction or running statements directly on the `Database`).
///
/// Additive steps (CREATE TABLE / INDEX / virtual-table / AFTER trigger) are
/// plain DDL. Column-shape changes go through
/// ``MigrationContext/recreateAndCopy(_:)``, which preserves rowids (and thus
/// foreign-key references) and rebuilds any dependent FTS index exactly once.
public struct Migration: Sendable {
    /// The version this migration brings the database to (>= 1).
    public let version: Int

    /// A human-readable label for diagnostics/logging (e.g. "add tags table").
    public let name: String

    /// The work, run inside the migrator's write transaction.
    public let body: @Sendable (MigrationContext) throws(DBError) -> Void

    public init(
        version: Int, name: String = "",
        body: @escaping @Sendable (MigrationContext) throws(DBError) -> Void
    ) {
        self.version = version
        self.name = name
        self.body = body
    }
}

/// The handle a ``Migration`` body uses to run statements inside the migrator's
/// transaction. A thin, intention-revealing wrapper over ADSQL's public
/// `SQLTransaction`: every statement it runs commits with the `schema_version`
/// bump or rolls back together.
///
/// Only INSERT/UPDATE/DELETE/DDL may run here (the underlying transaction block
/// forbids SELECT and transaction control), which is exactly the migration
/// vocabulary.
///
/// The wrapped `SQLTransaction` handle is valid only for the duration of the
/// migrator's transaction closure; the migrator never lets a context escape it.
public struct MigrationContext {
    // `SQLParameters` is part of ADSQL's `@_spi(ADDBEngine)` surface, so it is seen
    // as `internal` here — `run` therefore cannot be `@inlinable` (it would leak a
    // non-`@usableFromInline` type). The body is a thin DDL/DML pass-through whose
    // cost is the SQL execution, not the call, so nothing is lost by keeping it
    // out-of-line.
    // The memberwise init is `internal` (its only stored property is), so the
    // migrator can build a context while callers cannot — no explicit init needed.
    let txn: SQLTransaction

    /// Runs one DDL/DML statement inside the migration transaction.
    @discardableResult
    public func run(_ sql: String, _ parameters: Value...) throws(DBError) -> RunResult {
        try txn.run(sql, SQLParameters(positional: parameters))
    }

    /// Runs one DDL/DML statement with positional parameters.
    @discardableResult
    public func run(_ sql: String, _ parameters: [Value]) throws(DBError) -> RunResult {
        try txn.run(sql, SQLParameters(positional: parameters))
    }

    /// Runs one DDL/DML statement with named parameters.
    @discardableResult
    public func run(_ sql: String, named parameters: [String: Value]) throws(DBError) -> RunResult {
        try txn.run(sql, SQLParameters(named: parameters))
    }
}
