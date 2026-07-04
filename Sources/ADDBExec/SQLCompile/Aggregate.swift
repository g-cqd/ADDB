import ADSQL
import ADSQLModel

/// Aggregate functions: the core COUNT(*), COUNT(expr), SUM(expr), MIN/MAX/AVG(expr), plus
/// extension-registered aggregates (e.g. json_group_array/object) via `.custom`. TOTAL/GROUP_CONCAT
/// and COUNT(DISTINCT) are rejected at bind with named `sqlUnsupported` errors.
///
/// This is the plan-level spec the binder produces; the running accumulators + finalization
/// (`SlotState`/`GroupAccumulators`, which use the evaluator) live in the ADDB package's
/// `ADDBExec` target (`AggregateAccumulators.swift`).
struct AggregateSpec: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case countStar
        case count(SQLExpr)
        case sum(SQLExpr)
        /// MAX(expr)/MIN(expr): the running extremum, compared under the argument's collation
        /// (the `Binder.collation(of:)` of the un-bound argument — SQLite ranks min/max like an
        /// ORDER BY on the same column). NULL inputs are skipped; an empty/all-NULL group ⇒ NULL.
        case max(SQLExpr, Collation)
        case min(SQLExpr, Collation)
        /// AVG(expr): numeric-affinity sum over non-NULL inputs / their count. Always REAL when the
        /// group has a non-NULL value (matching SQLite), NULL for an empty/all-NULL group.
        case avg(SQLExpr)
        /// An extension-registered aggregate, resolved by name through `SQLAggregateRegistry` and
        /// folded by an `AggregateAccumulator`. `args` are the call's argument expressions
        /// (validated to the descriptor's arity at bind time).
        case custom(name: String, args: [SQLExpr])
    }
    let kind: Kind
}
