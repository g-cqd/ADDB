@_spi(ADDBEngine) import ADDBCore
import ADSQL
import ADSQLModel

/// The hash- and merge-join equi-join fast paths for `SelectExecutor` plus their
/// equi-key analysis. Split from `JoinExecutor.swift` to keep the file within the
/// gate; `runInnerHashJoin`/`runMergeJoin` are the entry points the nested-loop
/// driver tries before falling back.
extension SelectExecutor {
    /// Hash join for a 2-table INNER equi-join: builds a hash of the inner table
    /// keyed by the equi-join columns, then probes with each outer row — O(M+N), no
    /// per-outer index descent. Produces the same composite `RowContext` state as the
    /// nested loop, so `emit` (WHERE + projection/aggregation) is unchanged. Returns
    /// false when ineligible (not a single INNER join, no usable same-class/collation
    /// column equi key, or the build exceeds `budgetBytes`) → caller uses nested loop.
    ///
    /// Equi keys are extracted from the (already-bound) ON and key a `GroupKey`,
    /// whose equality matches SQL `=` for same-class/collation columns (no false
    /// negatives). Non-equi ON conjuncts are re-checked per match. A NULL probe key
    /// matches nothing (SQL `=` is unknown with NULL).
    static func runInnerHashJoin<R: PageResolver>(
        _ plan: BoundSelect, catalog: QueryCatalog, resolver: R, scanEnv: ScanEnv,
        budgetBytes: Int, emit: () throws(DBError) -> Void
    ) throws(DBError) -> Bool {
        let tables = catalog.tables
        let index = catalog.index
        let ftsRecords = catalog.ftsRecords
        let context = scanEnv.context
        let env = scanEnv.env
        let paramsEnv = scanEnv.paramsEnv
        guard plan.joins.count == 1, plan.joins[0].kind == .inner else { return false }
        let join = plan.joins[0]
        let innerDepth = join.table
        let binding = plan.binding

        var equiInner: [Int] = []
        var equiOuter: [SQLExpr] = []
        var equiCollations: [Collation] = []
        var residualConjuncts: [SQLExpr] = []
        for conjunct in andConjuncts(join.on) {
            if let key = hashEquiKey(conjunct, innerDepth: innerDepth, binding: binding) {
                equiInner.append(key.innerColumn)
                equiOuter.append(key.outerColumn)
                equiCollations.append(key.collation)
            } else {
                residualConjuncts.append(conjunct)
            }
        }
        guard !equiInner.isEmpty else { return false }
        let onResidualRaw: SQLExpr? =
            residualConjuncts.isEmpty
            ? nil : residualConjuncts.dropFirst().reduce(residualConjuncts[0]) { .binary(.and, $0, $1) }
        // Hoist query-invariant subtrees of the non-equi ON residual once (params
        // bound in `paramsEnv`); evaluated per matched inner row below.
        let onResidual = try onResidualRaw.map { e throws(DBError) in
            try SQLEval.foldInvariant(e, paramsEnv)
        }

        // SEMI-JOIN: when the inner is existence-only (no inner column is read by the
        // query) and the ON is pure equi (no residual), the inner row *values* are never
        // needed — build per-key COUNTS instead of materializing every inner row, then
        // emit `count` times per matching outer. Avoids the O(inner-rows) materialization
        // that makes the plain hash the wrong tool for a large symmetric existence join
        // (findings #1/#3); cardinality is preserved (COUNT(*) = Σ matched run lengths).
        if join.innerExistenceOnly, onResidual == nil {
            try runSemiJoin(
                plan, catalog: catalog, resolver: resolver, scanEnv: scanEnv,
                equiKeys: EquiKeys(inner: equiInner, outer: equiOuter, collations: equiCollations),
                emit: emit)
            return true
        }

        // BUILD: full scan of the inner table → hash[inner equi key] = [(rowid, full row)].
        var hash: [GroupKey: [(rowid: Int64, values: [Value])]] = [:]
        var approxBytes = 0
        var overBudget = false
        let innerTable = tables[innerDepth]
        unsafe try forEachRow(.table, table: innerTable, resolver: resolver) {
            rowid, span, score throws(DBError) in
            unsafe context.load(innerDepth, rowid: rowid, span: span, score: score)
            var keyValues: [Value] = []
            keyValues.reserveCapacity(equiInner.count)
            for column in equiInner { keyValues.append(try context.slots[innerDepth].value(at: column)) }
            let values = try context.slots[innerDepth].materialize()
            hash[GroupKey(keyValues, collations: equiCollations), default: []].append((rowid, values))
            approxBytes += 24 + values.count * 24
            if approxBytes > budgetBytes {
                overBudget = true
                return false
            }
            return true
        }
        if overBudget { return false }  // build emitted nothing → caller falls back to nested loop

        // PROBE: scan the outer (leading) source; look up each outer row's matches.
        // Lower the outer equi-key expressions (once per outer row) and the non-equi ON
        // residual (once per matched pair) to thunks — compiled under the compiled-
        // closures evaluator, tree-walk otherwise (`makeRowThunk`).
        let equiOuterThunks = equiOuter.map {
            makeRowThunk($0, context: context, params: scanEnv.params, env: env, evaluator: scanEnv.evaluator)
        }
        let onResidualThunk = onResidual.map {
            makeRowThunk($0, context: context, params: scanEnv.params, env: env, evaluator: scanEnv.evaluator)
        }
        let outerSource = try resolveSource(
            plan, table: tables[0], index: index, ftsRecords: ftsRecords, env: paramsEnv)
        unsafe try forEachRow(outerSource, table: tables[0], resolver: resolver) {
            rowid, span, score throws(DBError) in
            unsafe context.load(0, rowid: rowid, span: span, score: score)
            var probeValues: [Value] = []
            probeValues.reserveCapacity(equiOuterThunks.count)
            for thunk in equiOuterThunks { probeValues.append(try thunk()) }
            if probeValues.contains(where: { $0.isNull }) { return true }  // NULL never matches
            guard let matches = hash[GroupKey(probeValues, collations: equiCollations)] else { return true }
            for match in matches {
                context.loadMaterialized(innerDepth, rowid: match.rowid, values: match.values)
                if let onResidualThunk, SQLEval.truth(try onResidualThunk()) != .yes { continue }
                try emit()
            }
            return true
        }
        return true
    }

    /// SEMI-JOIN existence optimization: the inner is existence-only with a pure-equi
    /// ON, so its row values are never read — build per-key COUNTS, then emit `count`
    /// times per matching outer (cardinality preserved: COUNT(*) = Σ matched runs).
    private static func runSemiJoin<R: PageResolver>(
        _ plan: BoundSelect, catalog: QueryCatalog, resolver: R, scanEnv: ScanEnv,
        equiKeys: EquiKeys, emit: () throws(DBError) -> Void
    ) throws(DBError) {
        let innerDepth = plan.joins[0].table
        let context = scanEnv.context
        var counts: [GroupKey: Int] = [:]
        unsafe try forEachRow(.table, table: catalog.tables[innerDepth], resolver: resolver) {
            rowid, span, score throws(DBError) in
            unsafe context.load(innerDepth, rowid: rowid, span: span, score: score)
            var keyValues: [Value] = []
            keyValues.reserveCapacity(equiKeys.inner.count)
            for column in equiKeys.inner { keyValues.append(try context.slots[innerDepth].value(at: column)) }
            counts[GroupKey(keyValues, collations: equiKeys.collations), default: 0] += 1
            return true
        }
        let emptySpan = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
        // Lower the outer equi-key expressions once (compiled or tree-walk).
        let equiOuterThunks = equiKeys.outer.map {
            makeRowThunk(
                $0, context: context, params: scanEnv.params, env: scanEnv.env,
                evaluator: scanEnv.evaluator)
        }
        let outerSource = try resolveSource(
            plan, table: catalog.tables[0], index: catalog.index, ftsRecords: catalog.ftsRecords,
            env: scanEnv.paramsEnv)
        unsafe try forEachRow(outerSource, table: catalog.tables[0], resolver: resolver) {
            rowid, span, score throws(DBError) in
            unsafe context.load(0, rowid: rowid, span: span, score: score)
            var probeValues: [Value] = []
            probeValues.reserveCapacity(equiOuterThunks.count)
            for thunk in equiOuterThunks { probeValues.append(try thunk()) }
            if probeValues.contains(where: { $0.isNull }) { return true }  // NULL never matches
            guard let count = counts[GroupKey(probeValues, collations: equiKeys.collations)] else {
                return true
            }
            unsafe context.load(innerDepth, rowid: 0, span: emptySpan)
            for _ in 0 ..< count { try emit() }
            return true
        }
    }

    /// Merge-join existence/COUNT fast path. A 2-table INNER
    /// existence equi-join whose join-key columns each have a UNIQUE, NOT-NULL,
    /// single-column index (the binder's `mergePlan`; indexes resolved into
    /// `context.mergeIndexes`) needs no per-outer probe: lock-step the two sorted
    /// indexes and emit once per key present on both sides (the intersection).
    /// UNIQUE + NOT-NULL rules out dup-run cross-products and NULL non-matches, so
    /// the result is provably identical to the nested loop. A self-join is the case
    /// where the two indexes coincide (the two cursors walk the same tree in step).
    /// Returns false (→ the proven nested-loop driver) outside this subset.
    static func runMergeJoin<R: PageResolver>(
        _ plan: BoundSelect, tables: [Catalog.TableRecord],
        resolver: R, context: RowContext, emit: () throws(DBError) -> Void
    ) throws(DBError) -> Bool {
        guard let indexes = context.mergeIndexes,
            plan.joins.count == 1, plan.joins[0].kind == .inner, plan.joins[0].innerExistenceOnly,
            plan.isAggregated, plan.whereExpr == nil,
            !plan.finalizationReferencedTables.contains(0),
            !plan.finalizationReferencedTables.contains(1)
        else { return false }

        // Neither table's columns are read (existence + COUNT(*)-style), so empty
        // spans suffice; two ordered cursors lock-step on the key prefix.
        let emptySpan = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
        unsafe context.load(0, rowid: 0, span: emptySpan)
        unsafe context.load(1, rowid: 0, span: emptySpan)
        var outer = Cursor(resolver: resolver, tree: indexes.outer.handle)
        var inner = Cursor(resolver: resolver, tree: indexes.inner.handle)
        var oValid = try outer.move(to: .first)
        var iValid = try inner.move(to: .first)
        while oValid, iValid {
            let cmp = try compareMergeKeyPrefixes(&outer, &inner)
            if cmp == 0 {
                try emit()
                oValid = try outer.next()
                iValid = try inner.next()
            } else if cmp < 0 {
                oValid = try outer.next()
            } else {
                iValid = try inner.next()
            }
        }
        return true
    }

    /// Compares the two cursors' current index keys by their column prefix — the
    /// bytes before the 8-byte rowid suffix. Both cursors are valid.
    private static func compareMergeKeyPrefixes<R: PageResolver>(
        _ outer: inout Cursor<R>, _ inner: inout Cursor<R>
    ) throws(DBError) -> Int {
        var result = 0
        _ = unsafe try outer.withCurrent { (oKey, _) throws(DBError) -> Bool in
            let oPrefix = unsafe UnsafeRawBufferPointer(rebasing: oKey[0 ..< (oKey.count - 8)])
            _ = unsafe try inner.withCurrent { (iKey, _) throws(DBError) -> Bool in
                let iPrefix = unsafe UnsafeRawBufferPointer(rebasing: iKey[0 ..< (iKey.count - 8)])
                result = unsafe Node.compare(oPrefix, iPrefix)
                return true
            }
            return true
        }
        return result
    }

    private static func andConjuncts(_ expr: SQLExpr) -> [SQLExpr] {
        if case .binary(.and, let l, let r) = expr { return andConjuncts(l) + andConjuncts(r) }
        return [expr]
    }

    /// A hashable equi-join conjunct `inner.col = outer.col` (either operand order)
    /// where both are bound columns of the SAME storage class and collation — so a
    /// `GroupKey` match equals SQL `=` (no affinity coercion). nil otherwise.
    private static func hashEquiKey(
        _ conjunct: SQLExpr, innerDepth: Int, binding: QueryBinding
    ) -> (innerColumn: Int, outerColumn: SQLExpr, collation: Collation)? {
        guard case .binary(.eq, let lhs, let rhs) = conjunct else { return nil }
        func pair(
            _ innerSide: SQLExpr, _ outerSide: SQLExpr
        )
            -> (innerColumn: Int, outerColumn: SQLExpr, collation: Collation)?
        {
            guard case .boundColumn(let it, let ic) = innerSide, it == innerDepth,
                case .boundColumn(let ot, let oc) = outerSide, ot < innerDepth,
                binding.tables[it].columnTypes[ic] == binding.tables[ot].columnTypes[oc],
                binding.tables[it].columnCollations[ic] == binding.tables[ot].columnCollations[oc]
            else { return nil }
            return (ic, outerSide, binding.tables[it].columnCollations[ic])
        }
        return pair(lhs, rhs) ?? pair(rhs, lhs)
    }
}
