@_spi(ADDBEngine) import ADDBCore
import ADSQL
import ADSQLModel

/// Read-path execution helpers for `Statement`: the compound/select runners, the
/// correlated-subquery re-entry, and catalog record resolution. Split from
/// `Statement.swift` to keep the class body within the gate.
extension Statement {
    /// Combines a compound (UNION / UNION ALL) by running each arm and applying the
    /// compound's dedup/ORDER BY/LIMIT — always materialized (the dedup/sort spans arms).
    static func runCompound(
        _ compound: BoundCompound, txn: borrowing ReadTxn, params: SQLParameters,
        execution: ExecutionOptions
    ) throws(DBError) -> [SQLRow] {
        var combined: [[Value]] = []
        // Incremental UNION dedup: carry ONE running `Set<GroupKey>` + one output
        // array across arms rather than rebuilding a fresh set over `combined + armRows`
        // at every UNION arm (which is O(arms × totalRows)). `seen` mirrors `combined`'s
        // distinct keys and is valid only while `deduped` holds; a UNION ALL arm (or
        // arm 0) appends possible duplicates and clears it, so the next UNION rebuilds
        // the set once — exactly preserving `distinctRows(combined + armRows)`
        // (first-occurrence order under `outputCollations`).
        var seen = Set<GroupKey>()
        var deduped = false
        for (position, arm) in compound.arms.enumerated() {
            let armRows = try runSelect(
                arm.select, txn: txn, params: params, execution: execution
            )
            .map(\.values)
            if position == 0 {
                combined = armRows
                deduped = false
            } else if arm.op == .unionAll {
                combined += armRows
                deduped = false
            } else if deduped {
                // `combined` is already distinct and `seen` tracks its keys: vet only
                // the new arm's rows (incremental — O(armRows), not O(combined + armRows)).
                combined.reserveCapacity(combined.count + armRows.count)
                for row in armRows
                where seen.insert(GroupKey(row, collations: compound.outputCollations)).inserted {
                    combined.append(row)
                }
            } else {
                // A prior UNION ALL (or arm 0) may have left duplicates: rebuild the
                // distinct set once over the whole accumulated result + new arm, keeping
                // first occurrence — identical to `distinctRows(combined + armRows)`.
                seen.removeAll(keepingCapacity: true)
                var out: [[Value]] = []
                out.reserveCapacity(combined.count + armRows.count)
                for row in combined
                where seen.insert(GroupKey(row, collations: compound.outputCollations)).inserted {
                    out.append(row)
                }
                for row in armRows
                where seen.insert(GroupKey(row, collations: compound.outputCollations)).inserted {
                    out.append(row)
                }
                combined = out
                deduped = true
            }
        }
        return try SelectExecutor.finishCompound(combined, compound: compound, params: params)
    }

    static func runSelect(
        _ plan: BoundSelect, txn: borrowing ReadTxn, params: SQLParameters,
        execution: ExecutionOptions = .default,
        sink: (([Value]) throws(DBError) -> Bool)? = nil
    ) throws(DBError) -> [SQLRow] {
        // An FTS binding has no schema table; model it to the executor as a
        // rowid-keyed table whose handle is `.empty` (never scanned — its access is
        // `.fts`), and resolve its real FTS record for the MATCH evaluation.
        var tables: [Catalog.TableRecord] = []
        var ftsRecords: [String: Catalog.FTSRecord] = [:]
        for binding in plan.binding.tables {
            if binding.isFTS {
                let record = try txn.ftsRecord(binding.table)
                ftsRecords[binding.table] = record
                tables.append(
                    Catalog.TableRecord(
                        tableId: record.ftsId, handle: .empty,
                        definition: TableDefinition.syntheticFTS(binding.table)))
            } else {
                tables.append(try txn.tableRecord(binding.table))
            }
        }
        var index: Catalog.IndexRecord?
        if let name = plan.access.indexName ?? plan.distinctIndexName {
            index = try txn.indexRecord(name)
        }
        var joinIndexes: [Catalog.IndexRecord?] = []
        for join in plan.joins {
            if let name = join.access.indexName {
                joinIndexes.append(try txn.indexRecord(name))
            } else {
                joinIndexes.append(nil)
            }
        }
        // Capture Copyable snapshot handles (not the noncopyable txn) so the
        // escaping correlated-subquery runner can re-enter the executor.
        let resolver = txn.resolver
        let meta = txn.meta
        let cache = txn.schemaCache
        // One correlated-subquery plan cache per execution, shared (reference type) by
        // the runner across every outer row and nesting level: the bound plan + resolved
        // records are invariant across outer rows, so the bind/resolution is paid once
        // per distinct subquery instead of once per outer row.
        let subplanCache = SubplanCache()
        let runner: SelectExecutor.SubqueryRunner = {
            sub, outerContext, outerBinding throws(DBError) in
            try runScalarSubquery(
                sub, resolver: resolver,
                ctx: SubqueryContext(
                    meta: meta, schemaCache: cache, params: params, subplanCache: subplanCache),
                outer: (outerContext, outerBinding), depth: 1)
        }
        var mergeIndexes: (outer: Catalog.IndexRecord, inner: Catalog.IndexRecord)?
        if let mergePlan = plan.mergePlan {
            mergeIndexes = (
                outer: try resolveIndex(mergePlan.outerIndex, resolver: resolver, meta: meta, cache: cache),
                inner: try resolveIndex(mergePlan.innerIndex, resolver: resolver, meta: meta, cache: cache)
            )
        }
        return try SelectExecutor.run(
            plan, tables: tables, index: index, joinIndexes: joinIndexes, ftsRecords: ftsRecords,
            resolver: txn.resolver, params: params, subquery: runner, execution: execution,
            mergeIndexes: mergeIndexes, sink: sink)
    }

    /// Maximum correlated-subquery re-entrancy depth. The parser bounds *static*
    /// expression nesting, but a correlated scalar subquery re-enters the whole
    /// executor once *per outer row*, so without a runtime cap a deeply-nested
    /// correlated chain is both a stack-overflow and an N^depth wall-clock DoS.
    /// Mirrors `SQLTriggerEngine.maxDepth`.
    static let maxSubqueryDepth = 16

    /// Runs one correlated scalar subquery against the current outer row,
    /// returning the first row's first column (or NULL when empty).
    /// The invariant context threaded through a correlated subquery and its
    /// recursive re-entries: catalog meta, the optional schema cache, and the
    /// bound parameters. `resolver` stays separate (it carries the generic R).
    private struct SubqueryContext {
        let meta: Meta
        let schemaCache: SchemaCache?
        let params: SQLParameters
        /// Per-execution memo of bound subquery plans + resolved catalog records,
        /// shared (reference type) across the re-entrant runner and all nesting levels.
        let subplanCache: SubplanCache
    }

    /// A correlated subquery's bind + catalog resolution, memoized across outer rows.
    /// Both `Binder.bindQuery` and record resolution are pure functions of the subquery
    /// AST and the snapshot's fixed schema — never of the correlated outer values — so
    /// the plan and records are identical for every outer row; only the outer VALUES
    /// (threaded separately into `SelectExecutor.run`) change per row. Read-path only
    /// (writes reject subqueries), so the resolved record handles stay valid.
    private struct CachedSubplan {
        let plan: BoundSelect
        let tables: [Catalog.TableRecord]
        let index: Catalog.IndexRecord?
        let joinIndexes: [Catalog.IndexRecord?]
        let ftsRecords: [String: Catalog.FTSRecord]
    }

    /// Per-execution cache of bound correlated-subquery plans. `SQLSelect` is a value
    /// type (only `Equatable`, not `Hashable`), so entries are matched by `==`; a query
    /// has at most a handful of distinct subqueries, so the linear scan is trivial next
    /// to the bind + resolution it elides. Two structurally-equal subqueries share an
    /// entry safely (they bind identically). Single-threaded read path → no locking.
    private final class SubplanCache {
        private var entries: [(select: SQLSelect, subplan: CachedSubplan)] = []
        func lookup(_ select: SQLSelect) -> CachedSubplan? {
            for entry in entries where entry.select == select { return entry.subplan }
            return nil
        }
        func store(_ select: SQLSelect, _ subplan: CachedSubplan) {
            entries.append((select, subplan))
        }
    }

    private static func runScalarSubquery<R: PageResolver>(
        _ select: SQLSelect, resolver: R, ctx: SubqueryContext,
        outer: (context: SelectExecutor.RowContext, binding: QueryBinding), depth: Int
    ) throws(DBError) -> Value {
        let meta = ctx.meta
        let schemaCache = ctx.schemaCache
        let params = ctx.params
        let outerContext = outer.context
        let outerBinding = outer.binding
        guard depth <= Self.maxSubqueryDepth else {
            throw DBError.sqlRuntime("too many levels of correlated subquery nesting")
        }
        // Bind + resolve the subquery's catalog records ONCE per distinct subquery AST
        // (memoized), not per outer row: both are pure in the subquery and the snapshot's
        // fixed schema. Only the correlated outer values — passed via `outer:` to
        // `SelectExecutor.run` below — vary per row. Execution still re-enters per row,
        // so the depth guard above still bounds a correlated chain.
        let subplan: CachedSubplan
        if let cached = ctx.subplanCache.lookup(select) {
            subplan = cached
        } else {
            let schema: Schema
            if let schemaCache {
                schema = try schemaCache.schema(resolver: resolver, meta: meta)
            } else {
                schema = try Relation.loadState(resolver: resolver, mainTree: meta.mainTree).schema
            }
            guard case .select(let plan) = try Binder.bindQuery(select, schema: schema) else {
                throw DBError.sqlUnsupported("compound scalar subquery")
            }
            var tables: [Catalog.TableRecord] = []
            var ftsRecords: [String: Catalog.FTSRecord] = [:]
            for binding in plan.binding.tables {
                if binding.isFTS {
                    guard let record = try Relation.ftsRecord(resolver, mainTree: meta.mainTree, name: binding.table)
                    else { throw DBError.noSuchTable(binding.table) }
                    ftsRecords[binding.table] = record
                    tables.append(
                        Catalog.TableRecord(
                            tableId: record.ftsId, handle: .empty,
                            definition: TableDefinition.syntheticFTS(binding.table)))
                } else {
                    tables.append(
                        try resolveTable(binding.table, resolver: resolver, meta: meta, cache: schemaCache))
                }
            }
            var index: Catalog.IndexRecord?
            if let name = plan.access.indexName ?? plan.distinctIndexName {
                index = try resolveIndex(name, resolver: resolver, meta: meta, cache: schemaCache)
            }
            var joinIndexes: [Catalog.IndexRecord?] = []
            for join in plan.joins {
                if let name = join.access.indexName {
                    joinIndexes.append(try resolveIndex(name, resolver: resolver, meta: meta, cache: schemaCache))
                } else {
                    joinIndexes.append(nil)
                }
            }
            subplan = CachedSubplan(
                plan: plan, tables: tables, index: index, joinIndexes: joinIndexes,
                ftsRecords: ftsRecords)
            ctx.subplanCache.store(select, subplan)
        }
        let runner: SelectExecutor.SubqueryRunner = { sub, context, binding throws(DBError) in
            try runScalarSubquery(
                sub, resolver: resolver, ctx: ctx,
                outer: (context, binding), depth: depth + 1)
        }
        let rows = try SelectExecutor.run(
            subplan.plan, tables: subplan.tables, index: subplan.index,
            joinIndexes: subplan.joinIndexes, ftsRecords: subplan.ftsRecords,
            resolver: resolver, params: params, outer: (outerContext, outerBinding), subquery: runner)
        return rows.first?.values.first ?? .null
    }

    private static func resolveTable<R: PageResolver>(
        _ name: String, resolver: R, meta: Meta, cache: SchemaCache?
    ) throws(DBError) -> Catalog.TableRecord {
        let record =
            if let cache {
                try cache.tableRecord(resolver, meta: meta, name: name)
            } else {
                try Relation.tableRecord(resolver, mainTree: meta.mainTree, name: name)
            }
        guard let record else { throw DBError.noSuchTable(name) }
        return record
    }

    private static func resolveIndex<R: PageResolver>(
        _ name: String, resolver: R, meta: Meta, cache: SchemaCache?
    ) throws(DBError) -> Catalog.IndexRecord {
        let record =
            if let cache {
                try cache.indexRecord(resolver, meta: meta, name: name)
            } else {
                try Relation.indexRecord(resolver, mainTree: meta.mainTree, name: name)
            }
        guard let record else { throw DBError.noSuchIndex(name) }
        return record
    }
}
