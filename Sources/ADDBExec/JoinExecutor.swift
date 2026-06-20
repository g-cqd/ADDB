@_spi(ADDBEngine) import ADDBCore
import ADSQL
import ADSQLModel

/// Join execution for `SelectExecutor` (split from the
/// 1551-line Executor.swift). The right-recursive nested-loop driver
/// (`forEachFilteredRow`/`runJoin`) with LEFT null-extension and ON/WHERE
/// placement, plus the hash and merge equi-join fast paths and their
/// probe-key/existence/COUNT helpers. These are `SelectExecutor` statics kept in
/// an extension beside the scan core they reuse (`forEachRow`, `resolveSource`,
/// `RowContext`, `Accumulator`, `RowSource`), which the split promoted from
/// `private` to `internal`. Behaviour is unchanged — pure code motion + visibility.
extension SelectExecutor {
    /// Upper bound on the number of tables in a single join. The nested-loop driver in
    /// ``forEachFilteredRow(_:tables:index:joinIndexes:ftsRecords:resolver:context:env:paramsEnv:execution:foldedWhere:foldedJoinOn:_:)``
    /// recurses once per joined table, so this caps the recursion depth — a stack-safety and
    /// denial-of-service guard against a query that names pathologically many tables. 64 matches
    /// SQLite's join-table limit; no legitimate query comes close. (Mirrors ``SQLTriggerEngine``'s
    /// `maxDepth` guard.)
    static let maxJoinTables = 64

    /// The resolved per-row evaluation environments: the column-loading `context`,
    /// the per-row evaluator `env`, and the parameters-only `paramsEnv` (invariant folds).
    struct ScanEnv {
        let context: RowContext
        let env: SQLEvalEnv
        let paramsEnv: SQLEvalEnv
    }

    /// The residual WHERE and per-join ON predicates with query-invariant subtrees
    /// already hoisted to constants (see `runJoin`).
    struct FoldedPredicates {
        let whereClause: SQLExpr?
        let joinOn: [SQLExpr]
    }

    /// A hash/merge join's equi-key structure pulled from an ON clause: the inner
    /// column indices, the matching outer expressions, and per-pair collations.
    struct EquiKeys {
        let inner: [Int]
        let outer: [SQLExpr]
        let collations: [Collation]
    }

    /// Per-query state for the nested-loop driver — what `descend` would otherwise
    /// capture, held so it can live as a method off `forEachFilteredRow`'s body. One
    /// instance per call; never escapes.
    private final class JoinDriver<R: PageResolver> {
        let plan: BoundSelect
        let catalog: QueryCatalog
        let resolver: R
        let scanEnv: ScanEnv
        let folded: FoldedPredicates
        let body: () throws(DBError) -> Void
        var probeKeyBuffer: [UInt8] = []

        init(
            plan: BoundSelect, catalog: QueryCatalog, resolver: R, scanEnv: ScanEnv,
            folded: FoldedPredicates, body: @escaping () throws(DBError) -> Void
        ) {
            self.plan = plan
            self.catalog = catalog
            self.resolver = resolver
            self.scanEnv = scanEnv
            self.folded = folded
            self.body = body
            probeKeyBuffer.reserveCapacity(64)
        }

        func passesWhere() throws(DBError) -> Bool {
            guard let predicate = folded.whereClause else { return true }
            return SQLEval.truth(try SQLEval.evaluate(predicate, scanEnv.env)) == .yes
        }

        /// Right-recursive descent: one joined table per level. ON filters during
        /// matching, WHERE applies at the leaf, LEFT emits one null-extended row when
        /// the right side has no match. Bounded by `maxJoinTables` (checked by caller).
        func descend(_ depth: Int) throws(DBError) {
            if depth == catalog.tables.count {
                if try passesWhere() { try body() }
                return
            }
            let join = plan.joins[depth - 1]
            let joinIndex = depth - 1 < catalog.joinIndexes.count ? catalog.joinIndexes[depth - 1] : nil
            // Fast existence: a UNIQUE-index full-key equality probe on an existence-only
            // inner reduces to one seek with a zero-copy key. nil ⇒ the general path below.
            if join.innerExistenceOnly, let joinIndex,
                let hit = try SelectExecutor.fastExistence(
                    join: join, index: joinIndex, table: catalog.tables[depth],
                    scanEnv: scanEnv, resolver: resolver, buffer: &probeKeyBuffer)
            {
                if hit {
                    unsafe scanEnv.context.load(
                        depth, rowid: 0, span: UnsafeRawBufferPointer(start: nil, count: 0))
                    try descend(depth + 1)
                } else if join.kind == .left {
                    scanEnv.context.setNull(depth)
                    try descend(depth + 1)
                }
                return
            }
            var matched = false
            // Index-nested-loop: probe the inner index with the outer value (a superset);
            // the ON below is the residual. Falls back to a full inner scan on `.tableScan`.
            let innerSource = try SelectExecutor.resolveAccess(
                join.access, index: joinIndex, table: catalog.tables[depth],
                ftsRecords: catalog.ftsRecords, env: scanEnv.env)
            // Existence-only is sound only while the access stays an actual probe; an
            // unconvertible value degrades it to a scan, which must re-apply the ON.
            let existence: Bool
            switch innerSource {
                case .index, .rowids: existence = join.innerExistenceOnly
                case .table, .fts: existence = false
            }
            unsafe try SelectExecutor.forEachRow(
                innerSource, table: catalog.tables[depth], resolver: resolver, existenceOnly: existence
            ) {
                rowid, span, score throws(DBError) in
                unsafe scanEnv.context.load(depth, rowid: rowid, span: span, score: score)
                if existence {
                    matched = true
                    try descend(depth + 1)
                } else if SQLEval.truth(try SQLEval.evaluate(folded.joinOn[depth - 1], scanEnv.env)) == .yes {
                    matched = true
                    try descend(depth + 1)
                }
                return true
            }
            if join.kind == .left && !matched {
                scanEnv.context.setNull(depth)
                try descend(depth + 1)
            }
        }
    }

    /// The non-join row source: scan the single table's access path (decoding slot 0
    /// through a covering index's INCLUDE layout when applicable) and run `emit` per
    /// row. `emit` carries the residual-WHERE check.
    private static func forEachUnjoinedRow<R: PageResolver>(
        _ plan: BoundSelect, catalog: QueryCatalog, resolver: R, scanEnv: ScanEnv,
        emit: () throws(DBError) -> Void
    ) throws(DBError) {
        let source = try resolveSource(
            plan, table: catalog.tables[0], index: catalog.index, ftsRecords: catalog.ftsRecords,
            env: scanEnv.paramsEnv)
        let covering: [String]? = {
            if case .index(_, _, let includes) = source { return includes }
            return nil
        }()
        unsafe try forEachRow(source, table: catalog.tables[0], resolver: resolver) {
            rowid, span, score throws(DBError) in
            unsafe scanEnv.context.load(
                0, rowid: rowid, span: span, score: score, coveringIncludes: covering)
            try emit()
            return true
        }
    }

    /// Visits every post-WHERE composite row, loading `context` so `body` can
    /// read columns through the binding. Single-table queries scan the access
    /// path; joins drive a right-recursive nested loop — ON filters during
    /// matching, WHERE applies at the leaf (after any LEFT null-extension), and
    /// LEFT emits one null-extended row when the right side has no match.
    static func forEachFilteredRow<R: PageResolver>(
        _ plan: BoundSelect, catalog: QueryCatalog, resolver: R, scanEnv: ScanEnv,
        execution: ExecutionOptions = .default, folded: FoldedPredicates,
        _ body: @escaping () throws(DBError) -> Void
    ) throws(DBError) {
        // Bound the nested-loop join recursion before it starts: `descend` recurses once per joined
        // table, so a query naming thousands of tables would overflow the stack. Reject anything past
        // the cap deterministically (a `DBError`, never a crash); no legitimate query approaches it.
        guard catalog.tables.count <= Self.maxJoinTables else {
            throw DBError.sqlRuntime(
                "too many tables in a single join (\(catalog.tables.count) > \(Self.maxJoinTables))")
        }
        let driver = JoinDriver(
            plan: plan, catalog: catalog, resolver: resolver, scanEnv: scanEnv, folded: folded, body: body)
        let emit = { () throws(DBError) in if try driver.passesWhere() { try body() } }
        guard plan.isJoin else {
            try forEachUnjoinedRow(plan, catalog: catalog, resolver: resolver, scanEnv: scanEnv, emit: emit)
            return
        }
        // Merge join (existence/COUNT fast path); `.auto` picks it when eligible (one
        // ordered index pass beats M per-outer probes), else falls through to the loop.
        if execution.join == .merge || execution.join == .auto,
            try runMergeJoin(
                plan, tables: catalog.tables, resolver: resolver, context: scanEnv.context, emit: emit)
        {
            return
        }
        // Hash join (eligible 2-table INNER equi-join): build inner, probe outer — O(M+N).
        // Returns false when ineligible, falling through to the nested-loop driver below.
        if execution.join == .hash,
            try runInnerHashJoin(
                plan, catalog: catalog, resolver: resolver, scanEnv: scanEnv,
                budgetBytes: execution.hashJoinMemoryBudgetBytes, emit: emit)
        {
            return
        }

        let outerSource = try resolveSource(
            plan, table: catalog.tables[0], index: catalog.index, ftsRecords: catalog.ftsRecords,
            env: scanEnv.paramsEnv)
        unsafe try forEachRow(outerSource, table: catalog.tables[0], resolver: resolver) {
            rowid, span, score throws(DBError) in
            unsafe scanEnv.context.load(0, rowid: rowid, span: span, score: score)
            try driver.descend(1)
            return true
        }
    }

    /// Single-seek existence for a UNIQUE-index full-key equality probe on an
    /// existence-only join inner. Builds the probe key (zero-copy from the outer
    /// columns' page bytes where possible) into the reused `buffer`, then checks the
    /// index for a matching entry — no bounds, no `RowCursor`, no table descent.
    /// Returns nil when ineligible (caller uses the general path); `.some(hit)` when
    /// existence was resolved. UNIQUE-only: existence (descend once) preserves join
    /// cardinality, while non-unique fan-out keeps the enumerating existence path.
    private static func fastExistence<R: PageResolver>(
        join: BoundJoin, index: Catalog.IndexRecord, table: Catalog.TableRecord,
        scanEnv: ScanEnv, resolver: R, buffer: inout [UInt8]
    ) throws(DBError) -> Bool? {
        let context = scanEnv.context
        let env = scanEnv.env
        guard index.definition.unique,
            case .index(let name, let probes, _, _) = join.access,
            name == index.definition.name, probes.count == 1,
            probes[0].trailing == nil,
            probes[0].equality.count == index.definition.columns.count
        else { return nil }
        let tableColumns = index.definition.columns.compactMap { table.definition.columnIndex(of: $0) }
        guard tableColumns.count == index.definition.columns.count else { return nil }
        let collations = Relation.indexCollations(index.definition, table: table.definition)

        buffer.removeAll(keepingCapacity: true)
        for (position, expr) in probes[0].equality.enumerated() {
            let idxType = table.definition.columns[tableColumns[position]].type
            guard
                try appendProbeField(
                    expr, idxType: idxType, collation: collations[position],
                    context: context, env: env, into: &buffer)
            else { return nil }  // non-column / class mismatch / NULL / NaN → general path
        }

        var cursor = Cursor(resolver: resolver, tree: index.handle)
        let prefixLen = buffer.count
        // `withUnsafeBytes` is untyped-rethrows; capture into a `Result` (as
        // `Relation.firstRowid` does) to stay in `throws(DBError)`.
        var outcome: Result<Bool, DBError> = .success(false)
        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            do throws(DBError) {
                _ = unsafe try cursor.seek(raw)
                guard cursor.isValid else { return }
                // stored index keys are `columns ++ 8-byte rowid`, so `seek` never
                // reports an exact hit on the column prefix — verify the entry's prefix
                // equals the probe (UNIQUE ⇒ at most one such entry).
                outcome = .success(
                    unsafe try cursor.withCurrent { (key, _) throws(DBError) -> Bool in
                        guard key.count == prefixLen + 8 else { return false }
                        return unsafe raw.elementsEqual(UnsafeRawBufferPointer(rebasing: key[0 ..< prefixLen]))
                    } ?? false)
            } catch {
                outcome = .failure(error)
            }
        }
        return try outcome.get()
    }

    /// Encodes one equality-probe field into `buffer` directly from the outer
    /// column's bytes (TEXT/BLOB zero-copy; INTEGER/REAL from the cached value),
    /// byte-identical to `KeyCodec.append`. Returns false to fall back to the general
    /// (Value-coercing) path: a non-`.boundColumn` expr, an outer storage class that
    /// differs from the index column's, a null-extended outer, a NULL/absent value,
    /// or NaN.
    private static func appendProbeField(
        _ expr: SQLExpr, idxType: ColumnType, collation: Collation,
        context: RowContext, env: SQLEvalEnv, into buffer: inout [UInt8]
    ) throws(DBError) -> Bool {
        guard case .boundColumn(let outerTable, let outerCol) = expr,
            env.boundColumnType(outerTable, outerCol) == idxType,
            !context.nullExtended[outerTable]
        else { return false }
        let slot = context.slots[outerTable]
        switch idxType {
            case .text:
                return unsafe try slot.withTextBytes(at: outerCol) { bytes in
                    guard let bytes = unsafe bytes else { return false }
                    unsafe KeyCodec.appendTextBytes(bytes, collation: collation, to: &buffer)
                    return true
                }
            case .blob:
                return unsafe try slot.withBlobBytes(at: outerCol) { bytes in
                    guard let bytes = unsafe bytes else { return false }
                    unsafe KeyCodec.appendBlobBytes(bytes, to: &buffer)
                    return true
                }
            case .integer:
                guard case .integer(let value) = try slot.value(at: outerCol) else { return false }
                KeyCodec.appendInteger(value, to: &buffer)
                return true
            case .real:
                guard case .real(let value) = try slot.value(at: outerCol), !value.isNaN else { return false }
                try KeyCodec.appendReal(value, to: &buffer)
                return true
        }
    }

    static func runJoin<R: PageResolver>(
        _ plan: BoundSelect, catalog: QueryCatalog, resolver: R, params: SQLParameters,
        outer: (context: RowContext, binding: QueryBinding)?, subquery: @escaping SubqueryRunner,
        execution: ExecutionOptions = .default,
        mergeIndexes: (outer: Catalog.IndexRecord, inner: Catalog.IndexRecord)? = nil
    ) throws(DBError) -> [SQLRow] {
        let context = RowContext(definitions: catalog.tables.map(\.definition))
        context.mergeIndexes = mergeIndexes
        let env = rowEnv(plan, context: context, params: params, outer: outer, subquery: subquery)
        let paramsEnv = SQLEvalEnv.parametersOnly(now: params.now) { p throws(DBError) in try params.lookup(p) }
        let collectKeys = !plan.orderBy.isEmpty
        let bounds = try sliceBounds(plan, params: params)

        // Query-invariant hoisting (once per execution, params bound in `paramsEnv`):
        // pre-evaluate every param/literal-only subtree of the WHERE / each ON / the
        // projection outputs / the ORDER BY keys, so the per-row tree-walk sees a
        // `.literal` instead of recomputing it. This is the join path's dominant
        // win on the apple-docs `/search` query — the tier CASE's `$raw_lc || '%'`
        // LIKE prefix was rebuilt (malloc + scalar map) for every matched row even
        // though it is the same for all rows. Folding never collapses a subtree that
        // reads a column/aggregate/subquery (those stay intact, children folded), so
        // results are identical. The hash/merge equi-key analysis below reads the
        // UNFOLDED `plan.joins[].on`, so its structure is untouched.
        let foldedWhere = try plan.whereExpr.map { e throws(DBError) in
            try SQLEval.foldInvariant(e, paramsEnv)
        }
        let foldedJoinOn = try plan.joins.map { j throws(DBError) in
            try SQLEval.foldInvariant(j.on, paramsEnv)
        }
        let foldedOutputs = try plan.outputs.map { o throws(DBError) in
            try SQLEval.foldInvariant(o.expr, paramsEnv)
        }
        let foldedOrderBy = try plan.orderBy.map { t throws(DBError) in
            try SQLEval.foldInvariant(t.expr, paramsEnv)
        }

        // Bounded top-N: an ORDER BY + small positive LIMIT (no DISTINCT) keeps only
        // `offset+limit` rows in a sorted buffer during the scan instead of
        // materializing and sorting every matched row — and projects the full output
        // tuple ONLY for rows that make the cut (the dominant cost on the apple-docs
        // `/search` join, thousands of FTS matches but LIMIT 20). The keep
        // rule, tie-break (insert-after-equal ⇒ scan order), and final slice are
        // byte-identical to the collect-all + `sortedOrder` + `sliceBounds` path below
        // (`sortedOrder` is stable on `lhs < rhs`, and the FTS docid set arrives in
        // ascending rowid order, so equal-key runs keep the same order either way).
        // DISTINCT is excluded: dedup must see the whole set before LIMIT, so a row
        // outside the top-N keys could still be a needed unique representative.
        if collectKeys, !plan.distinct, let bounds, let limit = bounds.limit, limit >= 1 {
            let bound = bounds.offset + limit
            if bound >= 1, bound <= 4096 {
                var buffer = TopNBuffer(
                    capacity: bound, terms: plan.orderBy, collations: plan.orderCollations)
                try forEachFilteredRow(
                    plan, catalog: catalog, resolver: resolver,
                    scanEnv: ScanEnv(context: context, env: env, paramsEnv: paramsEnv),
                    execution: execution,
                    folded: FoldedPredicates(whereClause: foldedWhere, joinOn: foldedJoinOn)
                ) { () throws(DBError) in
                    var keys: [Value] = []
                    keys.reserveCapacity(foldedOrderBy.count)
                    for term in foldedOrderBy { keys.append(try SQLEval.evaluate(term, env)) }
                    // Only project the full tuple when the row qualifies for the buffer.
                    if buffer.wouldDrop(keys) { return }
                    var projected: [Value] = []
                    projected.reserveCapacity(foldedOutputs.count)
                    for output in foldedOutputs { projected.append(try SQLEval.evaluate(output, env)) }
                    buffer.insert(keys: keys, row: projected)
                }
                let kept = buffer.sortedRows()
                let lower = min(bounds.offset, kept.count)
                return kept[lower...].map { SQLRow(header: plan.header, values: $0) }
            }
        }

        var rows: [[Value]] = []
        var sortKeys: [[Value]] = []
        try forEachFilteredRow(
            plan, catalog: catalog, resolver: resolver,
            scanEnv: ScanEnv(context: context, env: env, paramsEnv: paramsEnv),
            execution: execution,
            folded: FoldedPredicates(whereClause: foldedWhere, joinOn: foldedJoinOn)
        ) { () throws(DBError) in
            var projected: [Value] = []
            projected.reserveCapacity(foldedOutputs.count)
            for output in foldedOutputs { projected.append(try SQLEval.evaluate(output, env)) }
            rows.append(projected)
            if collectKeys {
                var keys: [Value] = []
                keys.reserveCapacity(foldedOrderBy.count)
                for term in foldedOrderBy { keys.append(try SQLEval.evaluate(term, env)) }
                sortKeys.append(keys)
            }
        }

        if plan.distinct {
            (rows, sortKeys) = deduplicate(
                rows, sortKeys: sortKeys, ordered: collectKeys, collations: plan.outputCollations)
        }
        if collectKeys {
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
}

/// A fixed-capacity ascending top-N buffer for the join path: holds the best
/// `capacity` rows seen so far, ordered by `terms`/`collations`. The keep rule,
/// the insert-after-equal tie-break (so an equal-key run keeps scan order), and
/// the eventual `sortedRows` order are identical to the single-table
/// `SelectExecutor.Accumulator` top-N and the collect-all `sortedOrder` path — so
/// substituting it never changes results, only how many rows are projected/kept.
struct TopNBuffer {
    private let capacity: Int
    private let terms: [SQLOrderingTerm]
    private let collations: [Collation]
    private var rows: [[Value]] = []
    private var keys: [[Value]] = []

    init(capacity: Int, terms: [SQLOrderingTerm], collations: [Collation]) {
        self.capacity = capacity
        self.terms = terms
        self.collations = collations
        rows.reserveCapacity(capacity)
        keys.reserveCapacity(capacity)
    }

    /// True when the buffer is full and `candidate` does NOT order before the worst
    /// kept key — the row would be dropped, so the caller can skip projecting it.
    func wouldDrop(_ candidate: [Value]) -> Bool {
        rows.count >= capacity && !orderBefore(candidate, keys[capacity - 1])
    }

    /// Inserts a qualifying row into the sorted buffer, evicting the worst when over
    /// capacity. (Call only when `wouldDrop` is false.)
    mutating func insert(keys candidate: [Value], row: [Value]) {
        var lo = 0
        var hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            // Upper bound: an equal key inserts AFTER existing entries, so a run of
            // tied sort keys keeps scan order (ascending rowid) — matching the
            // collect-all `sortedOrder` (stable) and the single-table top-N.
            if orderBefore(candidate, keys[mid]) { hi = mid } else { lo = mid + 1 }
        }
        rows.insert(row, at: lo)
        keys.insert(candidate, at: lo)
        if rows.count > capacity {
            rows.removeLast()
            keys.removeLast()
        }
    }

    /// The kept rows in ascending ORDER BY order (already maintained sorted).
    consuming func sortedRows() -> [[Value]] { rows }

    /// Does sort key `a` order strictly before `b` under the ORDER BY terms?
    private func orderBefore(_ a: [Value], _ b: [Value]) -> Bool {
        for position in terms.indices {
            let comparison = SelectExecutor.orderCompare(a[position], b[position], collations[position])
            if comparison != 0 { return terms[position].descending ? comparison > 0 : comparison < 0 }
        }
        return false
    }
}
