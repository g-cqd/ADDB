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
        for (position, arm) in compound.arms.enumerated() {
            let armRows = try runSelect(
                arm.select, txn: txn, params: params, execution: execution
            )
            .map(\.values)
            if position == 0 {
                combined = armRows
            } else if arm.op == .unionAll {
                combined += armRows
            } else {
                combined = SelectExecutor.distinctRows(
                    combined + armRows, collations: compound.outputCollations)
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
        let runner: SelectExecutor.SubqueryRunner = {
            sub, outerContext, outerBinding throws(DBError) in
            try runScalarSubquery(
                sub, resolver: resolver,
                ctx: SubqueryContext(meta: meta, schemaCache: cache, params: params),
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
        let runner: SelectExecutor.SubqueryRunner = { sub, context, binding throws(DBError) in
            try runScalarSubquery(
                sub, resolver: resolver, ctx: ctx,
                outer: (context, binding), depth: depth + 1)
        }
        let rows = try SelectExecutor.run(
            plan, tables: tables, index: index, joinIndexes: joinIndexes, ftsRecords: ftsRecords,
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
