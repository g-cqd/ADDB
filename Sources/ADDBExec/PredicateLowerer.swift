//
//  PredicateLowerer.swift
//  ADDBExec
//
//  The per-execution preparation every executor does before it scans a row: hoist the
//  query-invariant subtrees of each expression, then compile what remains to a per-row thunk.
//
//  Both halves were open-coded in Executor, AggregateExecutor, JoinExecutor and
//  JoinExecutor+EquiJoin — 14 `SQLEval.foldInvariant` call sites across the four, each wrapped in
//  the same three-line `map { e throws(DBError) in ... }` shape, plus a local `makeThunk` closure
//  re-capturing the same five values. Holding that context once lets an executor state only WHICH
//  expressions it needs lowered.
//

import ADSQL
import ADSQLModel

/// Hoists query-invariant subtrees and lowers expressions to per-row thunks, holding the
/// per-execution context so each call site names only the expression.
///
/// **Hoisting** pre-evaluates every param/literal-only subtree against `paramsEnv`, so the per-row
/// tree-walk sees a `.literal` instead of recomputing it. On the apple-docs `/search` query this is
/// the dominant win: the tier CASE's `$raw_lc || '%'` LIKE prefix was rebuilt (malloc + scalar map)
/// for every matched row even though it is identical for all of them. Folding never collapses a
/// subtree that reads a column, an aggregate slot or a subquery — those stay intact with their
/// invariant children folded — so results are unchanged.
///
/// **Lowering** then compiles each surviving expression once, under the compiled-closures evaluator
/// where it can and the tree-walk evaluator otherwise. A compiled thunk reads slots directly and
/// bakes affinity/collation, skipping the recursive walk on every candidate row.
///
/// `env` is per-call rather than stored: `AggregateExecutor` lowers its WHERE / ON / GROUP BY
/// against the scan env but its HAVING / outputs / ORDER BY against the aggregate finalization env.
extension SelectExecutor {
    struct PredicateLowerer {
        /// Parameters-only environment — the one folding is safe against.
        let paramsEnv: SQLEvalEnv
        let context: RowContext
        let params: SQLParameters
        let evaluator: ExecutionOptions.Evaluator

        /// Hoist the query-invariant subtrees of `expr`.
        func fold(_ expr: SQLExpr) throws(DBError) -> SQLExpr {
            try SQLEval.foldInvariant(expr, paramsEnv)
        }

        /// Compile `expr` to a per-row thunk evaluated against `env`.
        func thunk(_ expr: SQLExpr, in env: SQLEvalEnv) -> CompiledEval.Thunk {
            makeRowThunk(expr, context: context, params: params, env: env, evaluator: evaluator)
        }

        /// Hoist then compile — the common case where an expression is used only per row.
        func lower(_ expr: SQLExpr, in env: SQLEvalEnv) throws(DBError) -> CompiledEval.Thunk {
            thunk(try fold(expr), in: env)
        }
    }
}
