@_spi(ADDBEngine) import ADDBCore
import ADSQL
import ADSQLModel
import OrderedCollections

/// Aggregate + GROUP BY execution for `SelectExecutor` (split
/// from Executor.swift). `runAggregated` drives the grouped/ungrouped aggregate
/// pipeline (COUNT/SUM/… accumulation, HAVING, finalization) and `aggregateEnv`
/// installs the per-group evaluation environment. `SelectExecutor` statics in an
/// extension; pure code motion + visibility.
extension SelectExecutor {
    /// The query's resolved catalog records: the base tables (binding order), the
    /// chosen leading index, per-join inner indexes, and FTS records by name.
    struct QueryCatalog {
        let tables: [Catalog.TableRecord]
        let index: Catalog.IndexRecord?
        let joinIndexes: [Catalog.IndexRecord?]
        let ftsRecords: [String: Catalog.FTSRecord]
    }

    static func runAggregated<R: PageResolver>(
        _ plan: BoundSelect, catalog: QueryCatalog, resolver: R, params: SQLParameters,
        outer: (context: RowContext, binding: QueryBinding)?, subquery: @escaping SubqueryRunner,
        execution: ExecutionOptions = .default,
        mergeIndexes: (outer: Catalog.IndexRecord, inner: Catalog.IndexRecord)? = nil
    ) throws(DBError) -> [SQLRow] {
        let context = RowContext(definitions: catalog.tables.map(\.definition))
        context.mergeIndexes = mergeIndexes
        let scanEnv = rowEnv(plan, context: context, params: params, outer: outer, subquery: subquery)
        let paramsEnv = SQLEvalEnv.parametersOnly(now: params.now) { p throws(DBError) in try params.lookup(p) }
        let columnCounts = plan.binding.tables.map(\.columnNames.count)
        let noGroupBy = plan.groupBy.isEmpty

        // Query-invariant hoisting (once per execution, params bound): pre-evaluate
        // param/literal-only subtrees of the WHERE / each ON / GROUP BY keys / HAVING
        // / outputs / ORDER BY so the per-row + per-group walks see constants. Folding
        // never collapses a subtree that reads a column or an aggregate slot (those
        // stay intact with their invariant children folded), so results are identical.
        let foldedWhere = try plan.whereExpr.map { e throws(DBError) in
            try SQLEval.foldInvariant(e, paramsEnv)
        }
        let foldedJoinOn = try plan.joins.map { j throws(DBError) in
            try SQLEval.foldInvariant(j.on, paramsEnv)
        }
        let foldedGroupBy = try plan.groupBy.map { e throws(DBError) in
            try SQLEval.foldInvariant(e, paramsEnv)
        }
        let foldedHaving = try plan.having.map { e throws(DBError) in
            try SQLEval.foldInvariant(e, paramsEnv)
        }
        let foldedOutputs = try plan.outputs.map { o throws(DBError) in
            try SQLEval.foldInvariant(o.expr, paramsEnv)
        }
        let foldedOrderBy = try plan.orderBy.map { t throws(DBError) in
            try SQLEval.foldInvariant(t.expr, paramsEnv)
        }

        // `OrderedDictionary` keeps the GROUP BY output order (first-insertion of each
        // key) intrinsically, so the finalization walk iterates it directly — no manual
        // `order: [GroupKey]` to keep in sync. Subscript-insert of a new key appends it;
        // re-touching an existing key leaves its position, matching the prior semantics.
        var groups: OrderedDictionary<GroupKey, (accumulators: GroupAccumulators, representative: [[Value]])> = [:]

        // An aggregate with no GROUP BY always produces exactly one row (COUNT 0,
        // SUM NULL over an empty input), so seed the single implicit group.
        let implicitKey = GroupKey([], collations: [])
        if noGroupBy {
            let empty = columnCounts.map { Array(repeating: Value.null, count: $0) }
            groups[implicitKey] = (GroupAccumulators(specs: plan.aggregates), empty)
        }

        try forEachFilteredRow(
            plan, catalog: catalog, resolver: resolver,
            scanEnv: ScanEnv(context: context, env: scanEnv, paramsEnv: paramsEnv),
            execution: execution,
            folded: FoldedPredicates(whereClause: foldedWhere, joinOn: foldedJoinOn)
        ) { () throws(DBError) in
            let key: GroupKey
            if noGroupBy {
                key = implicitKey
            } else {
                var parts: [Value] = []
                for expr in foldedGroupBy { parts.append(try SQLEval.evaluate(expr, scanEnv)) }
                key = GroupKey(parts, collations: plan.groupCollations)
            }
            if groups[key] == nil {
                var representative: [[Value]] = []
                for table in catalog.tables.indices {
                    // Skip materializing a table whose representative no output/HAVING/
                    // ORDER BY reads (e.g. COUNT(*)). Required for an existence-only inner,
                    // whose slot holds an empty span — decoding it would be wrong.
                    let needed = plan.finalizationReferencedTables.contains(table)
                    representative.append(
                        (needed && !context.nullExtended[table])
                            ? try context.slots[table].materialize()
                            : Array(repeating: Value.null, count: columnCounts[table]))
                }
                groups[key] = (GroupAccumulators(specs: plan.aggregates), representative)
            }
            try groups[key]!.accumulators.update(scanEnv)
        }

        var rows: [[Value]] = []
        var sortKeys: [[Value]] = []
        let collectKeys = !plan.orderBy.isEmpty
        for (_, group) in groups {
            let env = aggregateEnv(
                plan.binding, representative: group.representative,
                accumulators: group.accumulators, params: params)
            if let having = foldedHaving {
                if SQLEval.truth(try SQLEval.evaluate(having, env)) != .yes { continue }
            }
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

        return try sortSliceProject(
            rows, sortKeys: sortKeys, collectKeys: collectKeys, plan: plan, params: params)
    }

    /// DISTINCT dedup → ORDER BY sort → OFFSET/LIMIT slice → project to `SQLRow`:
    /// the shared materialization tail of the grouped aggregate pipeline.
    private static func sortSliceProject(
        _ rows: [[Value]], sortKeys: [[Value]], collectKeys: Bool, plan: BoundSelect,
        params: SQLParameters
    ) throws(DBError) -> [SQLRow] {
        var rows = rows
        var sortKeys = sortKeys
        if plan.distinct {
            (rows, sortKeys) = deduplicate(
                rows, sortKeys: sortKeys, ordered: collectKeys, collations: plan.outputCollations)
        }
        if collectKeys {
            let permutation = sortedOrder(sortKeys, terms: plan.orderBy, collations: plan.orderCollations)
            rows = permutation.map { rows[$0] }
        }
        if let bounds = try sliceBounds(plan, params: params) {
            let lower = min(bounds.offset, rows.count)
            let upper = bounds.limit.map { min(lower + $0, rows.count) } ?? rows.count
            rows = Array(rows[lower ..< upper])
        }
        return rows.map { SQLRow(header: plan.header, values: $0) }
    }

    /// Finalization env for one group: column references read the group's
    /// representative row; `aggregateResult` slots read the accumulators.
    private static func aggregateEnv(
        _ binding: QueryBinding, representative: [[Value]], accumulators: GroupAccumulators,
        params: SQLParameters
    ) -> SQLEvalEnv {
        SQLEvalEnv(
            parameter: { parameter throws(DBError) in try params.lookup(parameter) },
            column: { (qualifier, name, _) throws(DBError) in
                guard let (table, column) = binding.resolve(qualifier: qualifier, name: name) else {
                    throw DBError.noSuchColumn(table: qualifier ?? binding.tables[0].table, column: name)
                }
                return representative[table][column]
            },
            collationOf: { (qualifier, name) in
                binding.resolve(qualifier: qualifier, name: name)
                    .map { binding.tables[$0.table].columnCollations[$0.column] }
            },
            columnTypeOf: { (qualifier, name) in
                binding.resolve(qualifier: qualifier, name: name)
                    .map { binding.tables[$0.table].columnTypes[$0.column] }
            },
            boundColumn: { (table, column) throws(DBError) in representative[table][column] },
            boundCollation: { (table, column) in binding.tables[table].columnCollations[column] },
            boundColumnType: { (table, column) in binding.tables[table].columnTypes[column] },
            scalarSubquery: { _ throws(DBError) in
                throw DBError.sqlUnsupported("subquery (arrives in a later slice)")
            },
            aggregateValue: { slot throws(DBError) in accumulators.result(slot) })
    }
}
