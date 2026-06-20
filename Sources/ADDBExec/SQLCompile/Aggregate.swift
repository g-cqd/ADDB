import ADSQL

/// Aggregate functions: the core COUNT(*), COUNT(expr), SUM(expr), plus extension-registered
/// aggregates (e.g. json_group_array/object) via `.custom`. AVG/MIN/MAX/TOTAL/GROUP_CONCAT and
/// COUNT(DISTINCT) are rejected at bind with named `sqlUnsupported` errors.
///
/// This is the plan-level spec the binder produces; the running accumulators + finalization
/// (`SlotState`/`GroupAccumulators`, which use the evaluator) live in the ADDB package's
/// `ADDBExec` target (`AggregateAccumulators.swift`).
struct AggregateSpec: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case countStar
        case count(SQLExpr)
        case sum(SQLExpr)
        /// An extension-registered aggregate, resolved by name through `SQLAggregateRegistry` and
        /// folded by an `AggregateAccumulator`. `args` are the call's argument expressions
        /// (validated to the descriptor's arity at bind time).
        case custom(name: String, args: [SQLExpr])
    }
    let kind: Kind
}
