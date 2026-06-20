public import ADSQLModel

/// The relational layer's `RelationalParticipant`: the per-transaction owner of `RelationState`,
/// stashed opaquely on `TxnContext` so storage drives rollback/commit without naming relational
/// types. The `TxnContext.relation` accessor (below) reads/writes this participant's state, so the
/// engine's DML/DDL/catalog code keeps using `ctx.relation` unchanged.
///
/// This is the relational half of the storage→relational seam; once the engine splits into the
/// `ADStorageCore` / `ADDBEngine` targets, this file (and the accessor) live in `ADDBEngine`, while
/// the `RelationalParticipant` protocol stays in `ADStorageCore`.
@_spi(ADDBEngine) public final class RelationParticipant: RelationalParticipant {
    /// Relational state (catalog, handles, sequences), loaded lazily on first relational use.
    /// Value-typed, so a copy is a complete rollback snapshot.
    var state: RelationState?

    @_spi(ADDBEngine) public init() {}

    /// Commit: write changed catalog/sequence state back into the transaction's pages. A no-op when
    /// no relational state was loaded (raw key/value writes), matching the previous `ctx.relation !=
    /// nil` guard — `serializeState` itself returns early on a nil state.
    @_spi(ADDBEngine) public func serialize(into ctx: TxnContext) throws(DBError) {
        try Relation.serializeState(ctx: ctx)
    }

    /// Rollback snapshot: `RelationState` is value-typed (its arrays/dictionaries are COW), so a
    /// copy is a complete, cheap snapshot.
    @_spi(ADDBEngine) public func captureState() -> Any? { state }

    /// Rollback restore: a nil token (no relational state at the snapshot point) restores to nil.
    @_spi(ADDBEngine) public func restoreState(_ token: Any?) { state = token as? RelationState }
}

extension TxnContext {
    /// The relational per-transaction state, backed by the installed `RelationParticipant` (created
    /// lazily on first non-nil set). Storage holds only the opaque `participant`; this typed accessor
    /// — defined in the relational module — is what the engine's DML/DDL/catalog code reads and
    /// writes, so every `ctx.relation` call site is unchanged.
    @_spi(ADDBEngine) public var relation: RelationState? {
        get { (participant as? RelationParticipant)?.state }
        set {
            if let participant = participant as? RelationParticipant {
                participant.state = newValue
            } else if newValue != nil {
                let participant = RelationParticipant()
                participant.state = newValue
                self.participant = participant
            }
        }
    }
}
