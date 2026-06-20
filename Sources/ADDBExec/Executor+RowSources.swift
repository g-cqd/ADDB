@_spi(ADDBEngine) import ADDBCore
import ADSQL
import ADSQLModel

/// Row sources for single-table SELECT execution: the RowSource enum (table /
/// rowid / index / FTS), the unified `forEachRow` driver, and access-path → source
/// resolution. Split from `Executor.swift` to keep the enum body within the gate.
extension SelectExecutor {
    enum RowSource {
        case table
        case rowids([Int64])
        /// An index range scan. `covering` is non-nil (the index's full INCLUDE
        /// list) only for an index-only scan the binder proved safe: each row is
        /// served straight from the index leaf, no table descent. nil = descend.
        case index(Catalog.IndexRecord, [IndexBounds], covering: [String]?)
        /// An FTS5 MATCH source: the docids the FTS evaluator returns (ascending),
        /// each scored by bm25f. `query` is the UTF-8 of the resolved MATCH query
        /// string; `weights` are the per-column bm25 weights (already padded to the
        /// FTS column count, all-ones for plain `rank`).
        case fts(Catalog.FTSRecord, query: [UInt8], weights: [Double])
    }

    /// Accumulates surviving rows; `consume` returns false to request early
    /// termination (LIMIT reached on an already-ordered source).
    final class Accumulator {
        let context: RowContext
        /// Per-row evaluation thunks (tree-walk or compiled), prepared once.
        let residualThunk: CompiledEval.Thunk?
        let outputThunks: [CompiledEval.Thunk]
        /// ORDER BY terms (for the descending flags / count); evaluated via `orderThunks`.
        let orderBy: [SQLOrderingTerm]
        let orderThunks: [CompiledEval.Thunk]
        let orderCollations: [Collation]
        let collectKeys: Bool
        let sliceEnd: Int?
        /// Bounded top-N capacity (offset+limit) for an unordered ORDER BY + LIMIT
        /// without DISTINCT. When set, `rows`/`sortKeys` are kept sorted ascending
        /// and capped, so unkept rows are never projected and the full sort is
        /// avoided. nil = collect everything (the caller sorts).
        let topN: Int?
        /// First-occurrence dedup performed *during* the scan (SELECT DISTINCT on the
        /// single-table path): the projected row's `GroupKey` is inserted as it is
        /// consumed, so only ~distinct rows are ever retained instead of materializing
        /// every input row and deduping afterward. Equivalent to the post-scan
        /// `deduplicate` (same first-occurrence-in-scan-order semantics, same keys), so
        /// the executor skips that pass when `streamedDistinct` is true.
        let distinct: Bool
        let distinctCollations: [Collation]
        /// Single TEXT ORDER BY column for the zero-copy top-N early-drop (nil = the
        /// general `[Value]` sort-key path).
        let fastSort: (column: Int, descending: Bool, nocase: Bool)?
        /// index-only: the INCLUDE layout each row's span decodes through (the
        /// covering index's full `includes`); nil ⇒ the span is a full table record.
        let covering: [String]?
        var seenOutputs: Set<GroupKey> = []
        var seenRowids: Set<Int64>?
        var rows: [[Value]] = []
        var sortKeys: [[Value]] = []

        var presorted: Bool { topN != nil }
        var streamedDistinct: Bool { distinct }

        init(
            context: RowContext, residualThunk: CompiledEval.Thunk?, outputThunks: [CompiledEval.Thunk],
            orderBy: [SQLOrderingTerm], orderThunks: [CompiledEval.Thunk],
            orderCollations: [Collation], collectKeys: Bool,
            sliceEnd: Int?, topN: Int?, dedupRowids: Bool,
            distinct: Bool, distinctCollations: [Collation],
            fastSort: (column: Int, descending: Bool, nocase: Bool)?,
            covering: [String]?
        ) {
            self.context = context
            self.residualThunk = residualThunk
            self.outputThunks = outputThunks
            self.orderBy = orderBy
            self.orderThunks = orderThunks
            self.orderCollations = orderCollations
            self.collectKeys = collectKeys
            self.sliceEnd = sliceEnd
            self.topN = topN
            self.seenRowids = dedupRowids ? [] : nil
            self.distinct = distinct
            self.distinctCollations = distinctCollations
            self.fastSort = fastSort
            self.covering = covering
        }

        func consume(
            rowid: Int64, span: UnsafeRawBufferPointer, score: Double,
            sink: (([Value]) throws(DBError) -> Bool)? = nil
        ) throws(DBError) -> Bool {
            if seenRowids != nil {
                if seenRowids!.contains(rowid) { return true }
                seenRowids!.insert(rowid)
            }
            unsafe context.load(0, rowid: rowid, span: span, score: score, coveringIncludes: covering)
            if let residualThunk {
                if SQLEval.truth(try residualThunk()) != .yes { return true }
            }

            if let topN {
                // Fast early-drop: when the buffer is full and ORDER BY is a single TEXT
                // column, compare the candidate's bytes in place against the worst kept
                // entry — dropping a non-qualifying row without allocating a sort-key
                // String. Equivalent to (and superseded by) the `orderBefore` check below.
                if let fastSort, rows.count >= topN,
                    try fastDropsCandidate(fastSort, worstKey: sortKeys[topN - 1][0])
                {
                    return true
                }
                // Compute the sort key first; only project rows that make the cut.
                var keys: [Value] = []
                keys.reserveCapacity(orderThunks.count)
                for thunk in orderThunks { keys.append(try thunk()) }
                if rows.count >= topN, !orderBefore(keys, sortKeys[topN - 1]) { return true }
                insertSorted(keys, try project())
                return true
            }

            let projected = try project()
            // Stream DISTINCT: drop a row whose projected key was already seen. First
            // occurrence wins (scan order), matching the post-scan `deduplicate`.
            if distinct, !seenOutputs.insert(GroupKey(projected, collations: distinctCollations)).inserted {
                return true
            }
            // emit straight to the sink (no `rows` growth). `canStream` guarantees
            // there is no LIMIT/OFFSET/sort/top-N here, so scan order is the final order.
            if let sink { return try sink(projected) }
            rows.append(projected)
            if collectKeys {
                var keys: [Value] = []
                keys.reserveCapacity(orderThunks.count)
                for thunk in orderThunks { keys.append(try thunk()) }
                sortKeys.append(keys)
            }
            if let sliceEnd, rows.count >= sliceEnd { return false }
            return true
        }

        private func project() throws(DBError) -> [Value] {
            var projected: [Value] = []
            projected.reserveCapacity(outputThunks.count)
            for thunk in outputThunks { projected.append(try thunk()) }
            return projected
        }

        /// True when the bounded buffer is full and the candidate row (its `fastSort`
        /// column read in place) does NOT qualify for the top-N — letting `consume`
        /// drop it without materializing a sort-key `String`. Returns false (fall
        /// through to the full `[Value]` path) whenever it can't decide in place: a
        /// NULL or unstored candidate, or a non-contiguous/non-text worst key. The
        /// keep/drop rule mirrors `orderBefore` for one column (NULL-first, then DESC).
        private func fastDropsCandidate(
            _ fastSort: (column: Int, descending: Bool, nocase: Bool), worstKey: Value
        ) throws(DBError) -> Bool {
            let comparison: Int? = unsafe try context.slots[0]
                .withTextBytes(at: fastSort.column) {
                    (candidate) throws(DBError) -> Int? in
                    guard let candidate = unsafe candidate else { return nil }  // NULL/missing → full path
                    switch worstKey {
                        case .null:
                            return 1  // a non-null candidate sorts after a null worst (⇒ all kept are null)
                        case .text(let worst):
                            return worst.utf8.withContiguousStorageIfAvailable { storage -> Int in
                                let worstBytes = UnsafeRawBufferPointer(storage)
                                if fastSort.nocase {
                                    return unsafe SQLCompare.compareUTF8NoCase(candidate, worstBytes)
                                }
                                return unsafe SQLCompare.compareUTF8(candidate, worstBytes)
                            }
                        default:
                            return nil  // worst not text/null (shouldn't happen for a TEXT column)
                    }
                }
            guard let comparison else { return false }  // couldn't decide in place → keep
            let keep = fastSort.descending ? comparison > 0 : comparison < 0
            return !keep
        }

        /// Does sort key `a` order strictly before `b` under ORDER BY?
        private func orderBefore(_ a: [Value], _ b: [Value]) -> Bool {
            for position in orderBy.indices {
                let comparison = orderCompare(a[position], b[position], orderCollations[position])
                if comparison != 0 { return orderBy[position].descending ? comparison > 0 : comparison < 0 }
            }
            return false
        }

        /// Inserts into the ascending bounded buffer, dropping the worst when over
        /// capacity.
        private func insertSorted(_ keys: [Value], _ row: [Value]) {
            var lo = 0
            var hi = rows.count
            while lo < hi {
                let mid = (lo + hi) / 2
                // Upper bound: a key equal to an existing entry inserts AFTER it, so a
                // run of tied sort keys keeps scan order (ascending rowid) — matching
                // SQLite and the WAND path — instead of reversing each equal-key run.
                if orderBefore(keys, sortKeys[mid]) { hi = mid } else { lo = mid + 1 }
            }
            rows.insert(row, at: lo)
            sortKeys.insert(keys, at: lo)
            if let topN, rows.count > topN {
                rows.removeLast()
                sortKeys.removeLast()
            }
        }
    }

    /// Drives a row source, invoking `body` per `(rowid, recordSpan, score)`. The
    /// span is a zero-copy view into the mapped page, valid only for the duration
    /// of the `body` call; `score` is the bm25 relevance (0 for non-FTS sources).
    /// `body` returns false to stop early.
    static func forEachRow<R: PageResolver>(
        _ source: RowSource, table: Catalog.TableRecord, resolver: R, existenceOnly: Bool = false,
        ftsRankedTopK: Int? = nil, ftsScoreNeeded: Bool = true,
        _ body: (Int64, UnsafeRawBufferPointer, Double) throws(DBError) -> Bool
    ) throws(DBError) {
        switch source {
            case .table:
                var cursor = try RowCursor(
                    resolver: resolver, table: table, mode: .table, lowerKey: nil, upperKey: nil)
                unsafe try cursor.forEachRecordSpan { rowid, span throws(DBError) in
                    unsafe try body(rowid, span, 0)
                }
            case .rowids(let rowids):
                for rowid in rowids {
                    let outcome: Bool? = try Relation.withRowValue(
                        resolver, table.handle, key: KeyCodec.rowKey(rowid)
                    ) { ref throws(DBError) in
                        unsafe try BTree.withValueBytes(ref, resolver: resolver) { span throws(DBError) in
                            unsafe try body(rowid, span, 0)
                        }
                    }
                    if outcome == false { return }  // nil = no such row → skip
                }
            case .index(let index, let boundsList, let planCovering):
                // Index-only serving with NO table descent in two cases:
                // • existence-only (an existence-only join inner): `coveringIncludes: []`
                // selects the no-descent branch and serves an (unread) empty-ish span;
                // the rowid comes from the key and the caller reads no inner column.
                // • covering scan: the binder proved every needed base-table column is
                // the rowid-alias or an INCLUDE column, so serve them from the entry
                // value via the index's FULL `includes` layout. Existence-only wins when
                // both apply (it reads nothing, so the smaller [] is sufficient).
                let covering: [String]? = existenceOnly ? [] : planCovering
                for bounds in boundsList {
                    let (lower, upper) = try Relation.scanBounds(bounds, index: index, table: table)
                    var cursor = try RowCursor(
                        resolver: resolver, table: table, mode: .index(index),
                        lowerKey: lower, upperKey: upper, coveringIncludes: covering)
                    unsafe try cursor.forEachRecordSpan { rowid, span throws(DBError) in
                        unsafe try body(rowid, span, 0)
                    }
                }
            case .fts(let record, let queryBytes, let weights):
                // The FTS *query* language (MATCH parse, bm25f scoring, block-max WAND)
                // lives in the opt-in `ADSQLFullTextSearch` module, injected onto the
                // resolver as an `FTSEvaluation`. This layer holds only the access path;
                // it never names a query-language type.
                guard let fts = resolver.ftsEvaluator else {
                    throw DBError.sqlUnsupported(
                        "full-text search: import ADSQLFullTextSearch and call enableFullTextSearch()")
                }
                let empty = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
                // — block-max WAND: a ranked top-k (ORDER BY rank ASC + LIMIT k) over an
                // eligible query shape retrieves the top-k by dynamic pruning, scoring only
                // survivors (identical scores). nil ⇒ fall back to score-all.
                if let k = ftsRankedTopK,
                    let top = try fts.rankedTopK(
                        queryBytes: queryBytes, record: record, resolver: resolver, weights: weights, k: k)
                {
                    for entry in top where try unsafe !body(entry.docid, empty, entry.score) {
                        return
                    }
                    return
                }
                // Score-all: the MATCH membership docids (ascending), each handed to
                // `body` with an EMPTY span and its bm25f score — the FTS table's
                // `RowSlot` returns `.integer(docid)` for `rowid`, `.real` for `rank`, and
                // never reads the span; the join then descends on `base.id = fts.rowid`
                // exactly as for an ordinary rowid source. A membership-only MATCH (no
                // `rank`/`bm25` read) skips the scorer entirely.
                let (docids, scorer) = try fts.match(
                    queryBytes: queryBytes, record: record, resolver: resolver,
                    weights: weights, needScore: ftsScoreNeeded)
                for docid in docids {
                    let score = try scorer?.score(docid: docid) ?? 0
                    if try unsafe !body(docid, empty, score) { return }
                }
        }
    }

    /// Resolves the leading table's access plan into a concrete row source for
    /// this execution (probe values may be parameters; an unconvertible probe
    /// falls back to a table scan).
    static func resolveSource(
        _ plan: BoundSelect, table: Catalog.TableRecord, index: Catalog.IndexRecord?,
        ftsRecords: [String: Catalog.FTSRecord], env paramsEnv: SQLEvalEnv
    ) throws(DBError) -> RowSource {
        try resolveAccess(
            plan.access, index: index, table: table, ftsRecords: ftsRecords, env: paramsEnv)
    }

    /// Resolves an access plan into a row source against `env`. For the leading
    /// table `env` is parameters-only; for an index-nested-loop inner table it is
    /// the full row env (the probe values are outer columns, evaluated per outer
    /// row). An unconvertible/absent probe falls back to a scan — still correct
    /// via the residual (single-table WHERE, or the join's ON re-applied).
    static func resolveAccess(
        _ access: AccessPlan, index: Catalog.IndexRecord?, table: Catalog.TableRecord,
        ftsRecords: [String: Catalog.FTSRecord], env: SQLEvalEnv
    ) throws(DBError) -> RowSource {
        switch access {
            case .tableScan:
                return .table
            case .rowid(let exprs):
                return .rowids(try evaluateRowids(exprs, env))
            case .index(_, let probes, _, let covering):
                guard let index else { return .table }
                switch try buildIndexBounds(probes, index: index, table: table, env: env) {
                    case .scan: return .table  // unconvertible probe degraded to a scan: read full rows
                    case .bounds(let list): return .index(index, list, covering: covering)
                }
            case .fts(let name, let queryExpr, let weights):
                guard let record = ftsRecords[name] else {
                    throw DBError.noSuchTable(name)
                }
                // The query is a literal/parameter; evaluate it to text → UTF-8. A NULL or
                // non-text query matches nothing (empty bytes parse to an empty query).
                let value = try SQLEval.evaluate(queryExpr, env)
                guard case .text(let text) = value else {
                    throw DBError.sqlRuntime("MATCH query must be a text value")
                }
                return .fts(record, query: Array(text.utf8), weights: weights)
        }
    }
}
