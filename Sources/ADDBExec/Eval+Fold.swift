@_spi(ADDBEngine) import ADDBCore
import ADSQL
@_spi(ADDBEngine) import ADSQLModel

/// Query-invariant subexpression folding for `SQLEval`: `isInvariant`/`foldInvariant` precompute the
/// row-independent parts of an expression once. Split from `Eval.swift` to keep both within the gate.
extension SQLEval {
    // MARK: - Query-invariant subexpression folding

    /// Functions that are NOT a pure function of their arguments (their value can
    /// differ between two evaluations with identical inputs), so a subtree
    /// containing one must never be hoisted to a per-execution constant. ADSQL's
    /// only such function is `datetime('now')` (wall clock). Uppercased to match
    /// the case-insensitive dispatch in `SQLFunctions.call`.
    static let nonDeterministicFunctions: Set<String> = ["DATETIME"]

    /// True when `expr`'s ENTIRE subtree is *query-invariant*: it references no row
    /// value (`.column`/`.boundColumn`), no aggregate (`.aggregateResult`), and no
    /// subquery (`.scalarSubquery`), and contains no non-deterministic function or
    /// `MATCH` operator — so it evaluates to the SAME value for every row of a
    /// single execution once the parameters are bound. Such a subtree is exactly
    /// `.literal`/`.parameter` combined through pure operators/functions.
    ///
    /// This is the correctness crux of `foldInvariant`: it is the single predicate
    /// that decides whether a subtree may be pre-evaluated. It conservatively
    /// refuses (returns false) for anything row- or query-shape-dependent, and for
    /// `MATCH` (an access path that throws if row-evaluated). Mirrors the binder's
    /// `collectTableRefs`/`referencesOnlyBelow` walks so it cannot miss a case.
    static func isInvariant(_ expr: SQLExpr) -> Bool {
        // Iterative worklist: any row/aggregate/subquery reference, `MATCH`, or
        // non-deterministic function disqualifies the whole expression. Order is
        // irrelevant (logical AND over every subnode), so a deep chain is safe.
        var stack: [SQLExpr] = [expr]
        while let e = stack.popLast() {
            switch e {
                case .literal, .parameter:
                    break
                case .column, .boundColumn, .aggregateResult, .scalarSubquery:
                    // Row value / aggregate group value / per-row subquery result: never
                    // constant across the rows (or the database state) of one execution.
                    return false
                case .binary(.match, _, _):
                    // An access path the planner consumes; row-evaluating it is an error.
                    return false
                case .function(let name, let args, _, _):
                    if nonDeterministicFunctions.contains(name.uppercased()) { return false }
                    stack.append(contentsOf: args)
                case .binary(_, let l, let r):
                    stack.append(l)
                    stack.append(r)
                case .unary(_, let inner), .cast(let inner, _), .collate(let inner, _):
                    stack.append(inner)
                case .isNull(let inner, _):
                    stack.append(inner)
                case .like(let subject, let pattern, _):
                    stack.append(subject)
                    stack.append(pattern)
                case .inList(let subject, let items, _):
                    stack.append(subject)
                    stack.append(contentsOf: items)
                case .inJSONEach(let subject, let source, _):
                    stack.append(subject)
                    stack.append(source)
                case .caseWhen(let operand, let whens, let elseExpr):
                    if let operand { stack.append(operand) }
                    for when in whens {
                        stack.append(when.condition)
                        stack.append(when.result)
                    }
                    if let elseExpr { stack.append(elseExpr) }
            }
        }
        return true
    }

    /// Query-invariant subexpression hoisting (constant folding with bound
    /// parameters treated as per-execution constants). Rewrites `expr` so that
    /// every MAXIMAL subtree that `isInvariant` accepts is pre-evaluated ONCE
    /// (against `env`, which must already have the parameters bound) and replaced
    /// by a `.literal(value)`; row-dependent subtrees are left intact, with their
    /// invariant children folded.
    ///
    /// Applied once per execution before the row loop, this removes the per-row
    /// recomputation of param/literal-only work (e.g. the LIKE prefix pattern
    /// `? || '%'`, `CAST(? AS …)`, `LOWER(?)`) — the per-row evaluator then sees a
    /// `.literal` instead of rebuilding the same value for every matched row.
    ///
    /// Correctness: a whole subtree is evaluated only when `isInvariant` is true,
    /// i.e. it contains no row/aggregate/subquery reference and no
    /// non-deterministic function — so the single computed value provably equals
    /// what the per-row evaluator would have produced on every row. A subtree that
    /// is NOT invariant is never evaluated here; it is rebuilt from folded children
    /// (preserving its operator/shape exactly), so semantics are identical.
    ///
    /// Affinity / collation are preserved because we never fold a subtree that sits
    /// *directly* under a comparison or `IN` operator (the `affinityCritical`
    /// positions). There, a value's static comparison affinity (concat ⇒ TEXT,
    /// arithmetic/negate ⇒ NUMERIC, CAST ⇒ its type) and any explicit `COLLATE`
    /// drive `applyComparisonAffinity` / `resolveCollation`, and collapsing the
    /// subtree to a `.literal` (affinity `.none`, no collation) could change the
    /// comparison. So at those positions we keep the operand's top operator and
    /// fold only its (non-critical) children — the operand's affinity and collation
    /// are then byte-identical to the unfolded plan, while the param lookups /
    /// function calls inside it are still hoisted. Everywhere else (LIKE pattern,
    /// CASE arms, projection outputs, ORDER BY keys, boolean WHERE/ON, function
    /// args) affinity is irrelevant to the value, so the whole invariant subtree
    /// collapses to its constant.
    static func foldInvariant(_ expr: SQLExpr, _ env: SQLEvalEnv) throws(DBError) -> SQLExpr {
        try foldInvariant(expr, env, affinityCritical: false)
    }

    private static func foldInvariant(
        _ expr: SQLExpr, _ env: SQLEvalEnv, affinityCritical: Bool
    ) throws(DBError) -> SQLExpr {
        // Maximal invariant subtree → evaluate once, substitute the constant. Skipped
        // at a comparison/IN operand position, where the operator's static affinity
        // and any COLLATE must survive (fold the children instead, below).
        if !affinityCritical, isInvariant(expr) {
            return .literal(try evaluate(expr, env))
        }
        // Otherwise rebuild this node with each child folded. Children that are
        // themselves comparison/IN operands re-set `affinityCritical`.
        switch expr {
            case .literal, .parameter, .column, .boundColumn, .aggregateResult, .scalarSubquery:
                // Leaves: literals/params already handled above (or affinity-critical and
                // left intact); row/aggregate values and a per-row subquery are never
                // rewritten here (a subquery folds its own inner expressions when it runs).
                return expr
            case .binary(let op, let l, let r) where op.isComparison:
                // The operands drive comparison affinity + collation: fold their children
                // only, keeping each operand's top operator (its affinity is preserved).
                return .binary(
                    op, try foldInvariant(l, env, affinityCritical: true),
                    try foldInvariant(r, env, affinityCritical: true))
            case .binary:
                // Non-comparison (AND/OR/concat/arithmetic/json/MATCH): operands are not
                // affinity-critical. Flatten the left-leaning spine iteratively so a long
                // chain (notably AND/OR) cannot overflow, folding each right operand and the
                // base, then rebuild the identical left-leaning tree. `.match` reaches here
                // too (never invariant); folding its FTS-ref/query operands is a no-op.
                var rights: [(SQLBinaryOp, SQLExpr)] = []
                var node = expr
                while case .binary(let op, let l, let r) = node, !op.isComparison {
                    rights.append((op, r))
                    node = l
                }
                var acc = try foldInvariant(node, env)
                for (op, r) in rights.reversed() {
                    acc = .binary(op, acc, try foldInvariant(r, env))
                }
                return acc
            case .unary(let op, let inner):
                return .unary(op, try foldInvariant(inner, env))
            case .cast(let inner, let type):
                return .cast(try foldInvariant(inner, env), type)
            case .collate(let inner, let collation):
                return .collate(try foldInvariant(inner, env), collation)
            case .isNull(let inner, let negated):
                return .isNull(try foldInvariant(inner, env), negated: negated)
            case .like(let subject, let pattern, let negated):
                // The canonical win: `col LIKE ? || '%'` keeps `subject` (a column) but
                // folds the invariant `pattern` to a single `.literal(.text("term%"))`.
                // LIKE applies no affinity, so neither side is affinity-critical.
                return .like(
                    try foldInvariant(subject, env),
                    pattern: try foldInvariant(pattern, env), negated: negated)
            case .inList(let subject, let items, let negated):
                // `IN` compares the subject against each item under comparison affinity,
                // so every operand is affinity-critical.
                var folded: [SQLExpr] = []
                folded.reserveCapacity(items.count)
                for item in items { folded.append(try foldInvariant(item, env, affinityCritical: true)) }
                return .inList(
                    try foldInvariant(subject, env, affinityCritical: true), folded, negated: negated)
            case .inJSONEach(let subject, let source, let negated):
                // The subject is compared against each json_each value (affinity-critical);
                // the source is a plain TEXT argument (not).
                return .inJSONEach(
                    try foldInvariant(subject, env, affinityCritical: true),
                    source: try foldInvariant(source, env), negated: negated)
            case .caseWhen(let operand, let whens, let elseExpr):
                // With an operand, each WHEN condition is compared to it (affinity-critical
                // on both sides); without one, conditions are plain booleans. Results and
                // ELSE are values (not compared), so never affinity-critical.
                let operandCritical = operand != nil
                var foldedWhens: [SQLWhen] = []
                foldedWhens.reserveCapacity(whens.count)
                for when in whens {
                    foldedWhens.append(
                        SQLWhen(
                            condition: try foldInvariant(
                                when.condition, env, affinityCritical: operandCritical),
                            result: try foldInvariant(when.result, env)))
                }
                return .caseWhen(
                    operand: try operand.map { e throws(DBError) in
                        try foldInvariant(e, env, affinityCritical: true)
                    },
                    whens: foldedWhens,
                    elseExpr: try elseExpr.map { e throws(DBError) in try foldInvariant(e, env) })
            case .function(let name, let args, let star, let offset):
                // A non-deterministic function (or one with a row-dependent arg) reaches
                // here; fold only its invariant arguments, keep the call. Arguments are
                // function inputs, not comparison operands, so not affinity-critical.
                var foldedArgs: [SQLExpr] = []
                foldedArgs.reserveCapacity(args.count)
                for arg in args { foldedArgs.append(try foldInvariant(arg, env)) }
                return .function(name: name, args: foldedArgs, star: star, offset: offset)
        }
    }
}
