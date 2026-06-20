@_spi(ADDBEngine) import ADDBCore
import ADSQL
import ADSQLModel

/// SELECT execution over a `PageResolver` (committed reader or write-txn
/// overlay). The single-table pipeline is access-path source → WHERE filter →
/// projection → DISTINCT → ORDER BY → OFFSET/LIMIT (with a LIMIT early-exit
/// when the source order is final); joins add a nested-loop driver that
/// null-extends LEFT non-matches and applies ON during matching, WHERE after.
/// Results are fully materialized before the transaction closure returns.

enum SelectExecutor {
    static func run<R: PageResolver>(
        _ plan: BoundSelect, tables: [Catalog.TableRecord], index: Catalog.IndexRecord?,
        joinIndexes: [Catalog.IndexRecord?] = [],
        ftsRecords: [String: Catalog.FTSRecord] = [:],
        resolver: R, params: SQLParameters,
        outer: (context: RowContext, binding: QueryBinding)? = nil,
        subquery: @escaping SubqueryRunner = rejectSubquery,
        execution: ExecutionOptions = .default,
        mergeIndexes: (outer: Catalog.IndexRecord, inner: Catalog.IndexRecord)? = nil,
        // streaming: when set, the **unbounded single-table** path (no LIMIT/OFFSET,
        // no sort, no bounded-top-N) emits each surviving row to this sink as it is
        // produced — no full-result materialization — and returns `[]`. `sink` returns
        // false to stop early. Every other shape (sort/top-N/aggregate/join/distinct-
        // index) ignores it and returns the materialized `[SQLRow]` for the caller to
        // iterate; so a non-streamable query is still correct, just not bounded-memory.
        sink: (([Value]) throws(DBError) -> Bool)? = nil
    ) throws(DBError) -> [SQLRow] {
        let evaluator = execution.evaluator
        if plan.isAggregated {
            return try runAggregated(
                plan,
                catalog: QueryCatalog(
                    tables: tables, index: index, joinIndexes: joinIndexes, ftsRecords: ftsRecords),
                resolver: resolver, params: params, outer: outer, subquery: subquery, execution: execution,
                mergeIndexes: mergeIndexes)
        }
        if plan.isJoin {
            return try runJoin(
                plan, tables: tables, index: index, joinIndexes: joinIndexes, ftsRecords: ftsRecords,
                resolver: resolver, params: params, outer: outer, subquery: subquery, execution: execution,
                mergeIndexes: mergeIndexes)
        }
        // Index-ordered DISTINCT: emit one row per distinct index-key prefix, decoded
        // straight from the key (no table descent, no dedup set).
        if let name = plan.distinctIndexName, let index, index.definition.name == name {
            return try runDistinctIndex(plan, index: index, resolver: resolver, params: params)
        }
        let table = tables[0]
        let context = RowContext(definitions: tables.map(\.definition))
        let env = rowEnv(plan, context: context, params: params, outer: outer, subquery: subquery)
        let paramsEnv = SQLEvalEnv.parametersOnly(now: params.now) { p throws(DBError) in try params.lookup(p) }
        let bounds = try sliceBounds(plan, params: params)

        // Resolve the access path into a concrete row source, then decide whether
        // its order satisfies ORDER BY (so the sort and a LIMIT early-exit are
        // safe). An index probe whose values do not convert to the column class
        // falls back to a table scan — still correct via the residual WHERE.
        let source = try resolveSource(
            plan, table: table, index: index, ftsRecords: ftsRecords, env: paramsEnv)
        let stp = planSingleTable(plan, source: source, bounds: bounds)
        let collectKeys = stp.collectKeys
        let sliceEnd = stp.sliceEnd
        let topN = stp.topN
        let dedupRowids = stp.dedupRowids
        let ftsRankedTopK = stp.ftsRankedTopK
        let fastSort = stp.fastSort
        let residual = stp.residual
        let covering = stp.covering
        let ftsScoreNeeded = stp.ftsScoreNeeded
        // Query-invariant hoisting: pre-evaluate every param/literal-only subtree of
        // the residual / outputs / ORDER BY keys ONCE (params already bound in
        // `paramsEnv`) so the per-row thunk sees a `.literal`, not a recomputed
        // expression. Folded against `paramsEnv` (parameters-only): an invariant
        // subtree references no column, so the column-rejecting env is exactly right
        // (and would throw rather than misfold if one ever slipped through). The
        // compiled path already bakes literals, but still rebuilds e.g. `? || '%'`
        // per row — folding collapses that to a constant here too.
        let foldedResidual = try residual.map { e throws(DBError) in
            try SQLEval.foldInvariant(e, paramsEnv)
        }
        let foldedOutputs = try plan.outputs.map { o throws(DBError) in
            try SQLEval.foldInvariant(o.expr, paramsEnv)
        }
        let foldedOrderBy = try plan.orderBy.map { t throws(DBError) in
            try SQLEval.foldInvariant(t.expr, paramsEnv)
        }
        // Per-row evaluation: compile each expression once (compiled-closures path)
        // or wrap the tree-walk evaluator; an unsupported sub-expression falls back to
        // tree-walk so results are identical regardless of strategy.
        let makeThunk: (SQLExpr) -> CompiledEval.Thunk = { expr in
            if evaluator == .compiledClosures,
                let compiled = CompiledEval.compile(expr, context: context, params: params, env: env)
            {
                return compiled
            }
            return { () throws(DBError) -> Value in try SQLEval.evaluate(expr, env) }
        }
        // stream row-by-row only when nothing downstream needs the full set first —
        // no LIMIT/OFFSET slice (`bounds`), no post-scan sort (`collectKeys`), no bounded
        // top-N. (A LIMIT query is already memory-bounded, so it materializes-then-iterates.)
        let canStream = sink != nil && bounds == nil && !collectKeys && topN == nil
        // Pass the sink to `consume` (non-escaping) only when streamable; nil otherwise.
        let streamSink = canStream ? sink : nil
        let accumulator = Accumulator(
            context: context,
            residualThunk: foldedResidual.map(makeThunk),
            outputThunks: foldedOutputs.map(makeThunk),
            orderBy: plan.orderBy,
            orderThunks: foldedOrderBy.map(makeThunk),
            orderCollations: plan.orderCollations, collectKeys: collectKeys,
            sliceEnd: sliceEnd, topN: topN, dedupRowids: dedupRowids,
            distinct: plan.distinct, distinctCollations: plan.outputCollations, fastSort: fastSort,
            covering: covering)
        unsafe try forEachRow(
            source, table: table, resolver: resolver, ftsRankedTopK: ftsRankedTopK,
            ftsScoreNeeded: ftsScoreNeeded
        ) {
            rowid, span, score throws(DBError) in
            unsafe try accumulator.consume(
                rowid: rowid, span: span, score: score, sink: streamSink)
        }

        // rows were emitted to `sink` as produced — nothing to materialize/slice.
        if canStream { return [] }

        return finalize(accumulator: accumulator, plan: plan, collectKeys: collectKeys, bounds: bounds)
    }

    /// Derived single-table execution flags computed once from the bound plan and
    /// resolved row source: source-order finality, slice/top-N bounds, dedup/cover/
    /// FTS-scoring decisions, and the residual WHERE.
    private struct SingleTablePlan {
        let collectKeys: Bool
        let sliceEnd: Int?
        let topN: Int?
        let dedupRowids: Bool
        let ftsRankedTopK: Int?
        let fastSort: (column: Int, descending: Bool, nocase: Bool)?
        let residual: SQLExpr?
        let covering: [String]?
        let ftsScoreNeeded: Bool
    }

    /// Computes the single-table execution flags from the bound plan and resolved
    /// source (see `SingleTablePlan`). Pure — no I/O — so it factors cleanly out of `run`.
    private static func planSingleTable(
        _ plan: BoundSelect, source: RowSource, bounds: (offset: Int, limit: Int?)?
    ) -> SingleTablePlan {
        let ordered: Bool
        switch source {
            case .table:
                ordered = plan.orderBy.isEmpty || plan.rowidOrderSatisfiesOrderBy
            case .rowids:
                ordered = plan.accessYieldsOrder
            case .index(_, let list, _):
                ordered = plan.orderBy.isEmpty || (plan.accessYieldsOrder && list.count <= 1)
            case .fts:
                // The docid set is ascending; the planner sets accessYieldsOrder only
                // when there is no ORDER BY, so otherwise the executor sorts.
                ordered = plan.accessYieldsOrder
        }

        // Early-exit under LIMIT is sound only when the source order is final and
        // no later DISTINCT can drop earlier rows.
        let collectKeys = !ordered && !plan.orderBy.isEmpty
        let sliceEnd: Int? =
            (ordered && !plan.distinct)
            ? bounds.flatMap { b in b.limit.map { b.offset + $0 } } : nil
        // Bounded top-N: an unordered ORDER BY + (small) LIMIT without DISTINCT
        // keeps only offset+limit rows instead of materializing and sorting every
        // match. Larger limits fall back to collect-and-sort.
        let topN: Int? = {
            guard collectKeys, !plan.distinct, let bounds, let limit = bounds.limit, limit >= 1 else {
                return nil
            }
            let bound = bounds.offset + limit
            return bound >= 1 && bound <= 4096 ? bound : nil
        }()
        let dedupRowids: Bool = {
            if case .index(_, let list, _) = source { return list.count > 1 }
            return false
        }()
        // — block-max WAND ranked top-k: when the leading FTS source is ordered by
        // its bm25 `rank` slot ascending (best first) under a LIMIT, retrieve the
        // top-(offset+limit) by dynamic pruning instead of scoring the whole match set.
        // `k` is offset+limit (the slice drops the offset afterward). Enabled only for
        // `ORDER BY rank[, rowid]` ascending — exactly the heap's score-then-smallest-
        // rowid tiebreak — so the result is identical to score-all; any other shape (or
        // an ineligible query, decided inside) keeps the score-all path. nil = off.
        let ftsRankedTopK: Int? = {
            guard case .fts = source, let topN, isFTSRankAscendingOrder(plan.orderBy) else { return nil }
            return topN
        }()
        // Bounded top-N over a single TEXT ORDER BY column: lets `consume` drop a
        // non-qualifying row by comparing its column bytes in place (no sort-key
        // String) against the worst kept entry. nil = the general `[Value]` path.
        let fastSort: (column: Int, descending: Bool, nocase: Bool)? = {
            guard topN != nil, !plan.distinct, plan.orderBy.count == 1,
                case .boundColumn(let table, let column) = plan.orderBy[0].expr, table == 0,
                plan.binding.tables[0].columnTypes[column] == .text
            else { return nil }
            let collation = plan.orderCollations[0]
            guard collation == .binary || collation == .nocase else { return nil }
            return (column, plan.orderBy[0].descending, collation == .nocase)
        }()

        // A taken rowid/index probe exactly covers its equality conjuncts, so the
        // residual can drop them; a table scan (incl. the coercion fallback) must
        // re-check the full WHERE. The FTS source covers its MATCH conjunct (already
        // stripped from the WHERE at bind time), so any remaining WHERE applies.
        let residual: SQLExpr?
        switch source {
            case .table: residual = plan.whereExpr
            case .rowids, .index, .fts: residual = plan.residualWithoutCovered
        }
        // index-only: a covering source serves each row from the index entry's
        // value, so the slot must decode columns through the INCLUDE layout (the full
        // `includes` list) instead of by schema position. nil ⇒ ordinary record.
        let covering: [String]? = {
            if case .index(_, _, let includes) = source { return includes }
            return nil
        }()
        // for an FTS source, computing the per-doc bm25 score is dead work
        // unless the `rank` slot is actually read — by the projection, ORDER BY, or
        // residual — or WAND needs it. Skipping it makes a membership-only MATCH O(n)
        // instead of O(n²) (the scorer otherwise re-decodes the term's list per doc).
        let ftsScoreNeeded: Bool = {
            guard case .fts = source else { return true }
            if ftsRankedTopK != nil { return true }
            func reads(_ e: SQLExpr) -> Bool { exprReferences(e, table: 0, column: ftsRankSlot) }
            if plan.outputs.contains(where: { reads($0.expr) }) { return true }
            if plan.orderBy.contains(where: { reads($0.expr) }) { return true }
            if let residual, reads(residual) { return true }
            return false
        }()

        return SingleTablePlan(
            collectKeys: collectKeys, sliceEnd: sliceEnd, topN: topN, dedupRowids: dedupRowids,
            ftsRankedTopK: ftsRankedTopK, fastSort: fastSort, residual: residual,
            covering: covering, ftsScoreNeeded: ftsScoreNeeded)
    }

    /// Materializes the accumulator's rows: optional DISTINCT dedup, the collected-set
    /// sort (skipped when a bounded top-N already holds them ordered), then OFFSET/LIMIT.
    private static func finalize(
        accumulator: Accumulator, plan: BoundSelect, collectKeys: Bool,
        bounds: (offset: Int, limit: Int?)?
    ) -> [SQLRow] {
        var rows = accumulator.rows
        var sortKeys = accumulator.sortKeys
        if plan.distinct && !accumulator.streamedDistinct {
            (rows, sortKeys) = deduplicate(
                rows, sortKeys: sortKeys, ordered: collectKeys, collations: plan.outputCollations)
        }
        // Bounded top-N already holds rows sorted; otherwise sort the collected set.
        if collectKeys && !accumulator.presorted {
            let order = sortedOrder(sortKeys, terms: plan.orderBy, collations: plan.orderCollations)
            rows = order.map { rows[$0] }
        }
        if let bounds {
            let lower = min(bounds.offset, rows.count)
            let upper = bounds.limit.map { min(lower + $0, rows.count) } ?? rows.count
            rows = Array(rows[lower ..< upper])
        }
        return rows.map { SQLRow(header: plan.header, values: $0) }
    }

    /// Index-ordered DISTINCT: scans `index` in key order and emits one row per
    /// distinct key prefix (the bytes before the 8-byte rowid suffix), decoding the
    /// values straight from the key — no table descent, no dedup set. Since the
    /// index is sorted, equal prefixes are adjacent, so a byte compare against the
    /// previous emitted prefix is enough. The binder selects this path only when
    /// the index's key columns are exactly the (losslessly decodable) DISTINCT
    /// outputs with no WHERE/ORDER BY; LIMIT/OFFSET apply to the emitted rows.
    private static func runDistinctIndex<R: PageResolver>(
        _ plan: BoundSelect, index: Catalog.IndexRecord, resolver: R, params: SQLParameters
    ) throws(DBError) -> [SQLRow] {
        let columnCount = index.definition.columns.count
        var cursor = Cursor(resolver: resolver, tree: index.handle)
        guard try cursor.move(to: .first) else { return [] }
        var rows: [[Value]] = []
        var previous: [UInt8]?
        var hasRow = true
        while hasRow {
            let decoded: [Value]? =
                unsafe try cursor.withCurrent {
                    (key, _) throws(DBError) -> [Value]? in
                    guard key.count >= 8 else {
                        throw DBError.integrityFailure("index key missing rowid suffix")
                    }
                    let prefix = unsafe UnsafeRawBufferPointer(rebasing: key[0 ..< (key.count - 8)])
                    if let previous {
                        let same = previous.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                            unsafe Node.compare(bytes, prefix) == 0
                        }
                        if same { return nil }  // same distinct group as the previous entry
                    }
                    previous = unsafe [UInt8](prefix)
                    return unsafe try KeyCodec.decode(prefix, columns: columnCount)
                } ?? nil
            if let decoded { rows.append(decoded) }
            hasRow = try cursor.next()
        }
        if let bounds = try sliceBounds(plan, params: params) {
            let lower = min(bounds.offset, rows.count)
            let upper = bounds.limit.map { min(lower + $0, rows.count) } ?? rows.count
            rows = Array(rows[lower ..< upper])
        }
        return rows.map { SQLRow(header: plan.header, values: $0) }
    }
}
