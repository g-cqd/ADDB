public import ADSQLModel

/// The storage layer's hook into the SQL trigger engine. The relational DML
/// path persists triggers as opaque text and never parses or evaluates them;
/// when rows change it calls a registered `TriggerFiring` (the SQL layer's
/// engine) to fire any AFTER triggers, and on `DROP TABLE` it asks which
/// triggers target the dropped table. This inverts the dependency: storage
/// defines the protocol; the SQL layer implements it.
@_spi(ADDBEngine) public protocol TriggerFiring: Sendable {
    /// Fires every AFTER trigger registered for `(table, event)` against the
    /// supplied NEW/OLD row, in name order, within the same write transaction.
    func fire(
        _ ctx: TxnContext, event: TriggerEvent, table: String,
        old: [Value]?, new: [Value]?
    ) throws(DBError)

    /// The names of triggers whose target is `table` — for `DROP TABLE`
    /// cascade. The engine parses each stored trigger text to read its target.
    func triggerNames(
        targeting table: String, in ctx: TxnContext
    ) throws(DBError) -> [String]
}

/// The NEW/OLD row visible to an executing trigger body. `new`/`old` are the
/// affected row's values laid out per `table.columns`; either is nil for the
/// event that has no such row (INSERT has no OLD, DELETE has no NEW). All fields
/// are storage-layer types, so the frame lives here on the write context and the
/// SQL engine only sets/reads it.
@_spi(ADDBEngine) public struct TriggerFrame: Sendable {
    @_spi(ADDBEngine) public let table: TableDefinition
    @_spi(ADDBEngine) public let new: [Value]?
    @_spi(ADDBEngine) public let old: [Value]?

    @_spi(ADDBEngine) public init(table: TableDefinition, new: [Value]?, old: [Value]?) {
        self.table = table
        self.new = new
        self.old = old
    }
}
