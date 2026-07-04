import ADSQL
@_spi(ADDBEngine) import ADSQLModel

/// `bindSelect` phase helpers plus the bundles that thread bound state between them.
/// Split from `Binder.swift` so the binding phases factor out of `bindSelect`'s body
/// without inflating the enum.
extension Binder {
    /// The fully-bound clauses + access plans a SELECT's late analysis passes read.
    struct BoundClauses {
        let outputs: [BoundOutput]
        let whereExpr: SQLExpr?
        let residual: SQLExpr?
        let orderBy: [SQLOrderingTerm]
        let groupBy: [SQLExpr]
        let having: SQLExpr?
        let aggregates: [AggregateSpec]
        let joinsOn: [SQLExpr]
        let leadingAccess: AccessPlan
        let boundJoinAccess: [AccessPlan]
    }

    /// Output of `analyzeRefs`: which join inners are existence-only, which tables a
    /// group representative is read for, and whether any reference was unresolved.
    struct RefAnalysis {
        let existenceOnly: [Bool]
        let finalizationReferenced: Set<Int>
        let unknownRefs: Bool
    }

    /// Per-inner-table index-nested-loop access (see `Planner.planJoin`): for each raw
    /// join choose a probe (or scan), drop a `.fts`-consumed MATCH conjunct from the
    /// ON, and record whether the probe alone covers the whole ON (the bind-time half
    /// of the existence-only test).
    static func planJoins(
        rawJoins: [(kind: SQLJoinKind, depth: Int, on: SQLExpr)], tables: [TableBinding],
        binding: QueryBinding, schema: Schema
    ) throws(DBError) -> (joins: [BoundJoin], joinProbeCoversON: [Bool]) {
        var joins: [BoundJoin] = []
        var joinProbeCoversON: [Bool] = []
        for raw in rawJoins {
            let inner = tables[raw.depth]
            let innerDefinition =
                inner.isFTS ? syntheticFTSDefinition(inner.table) : schema.tables[inner.table]!
            let innerIndexes = inner.isFTS ? [] : schema.indexes(on: inner.table)
            let equalities = joinEqualities(raw.on, binding: binding, innerDepth: raw.depth)
            let (access, covered) = Planner.planJoin(
                equalities: equalities, inner: inner, on: raw.on,
                indexes: innerIndexes, definition: innerDefinition)
            var on = raw.on
            if case .fts = access, let (_, conjunct) = Planner.ftsMatchConjunct(raw.on, source: inner) {
                on = removeCovered(raw.on, [conjunct]) ?? .literal(.integer(1))
            }
            joinProbeCoversON.append(isExactEquality(access) && removeCovered(raw.on, covered) == nil)
            joins.append(
                BoundJoin(kind: raw.kind, table: raw.depth, on: on, access: access, innerExistenceOnly: false))
        }
        return (joins, joinProbeCoversON)
    }

    /// Column-reference analysis driving existence-only inners + aggregate
    /// materialization: `existenceOnly[d]` iff the probe covers d's whole ON and no
    /// other expression (incl. another join's ON) reads d; `finalizationReferenced`
    /// is the tables a group representative is read for; `unknownRefs` trips on any
    /// correlated/subquery reference (conservatively disabling every elision).
    static func analyzeRefs(
        clauses: BoundClauses, joins: [BoundJoin], joinProbeCoversON: [Bool], tableCount: Int
    ) -> RefAnalysis {
        var alwaysRefs: Set<Int> = []
        var unknownRefs = false
        for o in clauses.outputs { collectTableRefs(o.expr, into: &alwaysRefs, unknown: &unknownRefs) }
        if let w = clauses.whereExpr { collectTableRefs(w, into: &alwaysRefs, unknown: &unknownRefs) }
        if let h = clauses.having { collectTableRefs(h, into: &alwaysRefs, unknown: &unknownRefs) }
        for t in clauses.orderBy { collectTableRefs(t.expr, into: &alwaysRefs, unknown: &unknownRefs) }
        for g in clauses.groupBy { collectTableRefs(g, into: &alwaysRefs, unknown: &unknownRefs) }
        for spec in clauses.aggregates {
            switch spec.kind {
                case .countStar: break
                case .count(let e): collectTableRefs(e, into: &alwaysRefs, unknown: &unknownRefs)
                case .sum(let e): collectTableRefs(e, into: &alwaysRefs, unknown: &unknownRefs)
                case .max(let e, _): collectTableRefs(e, into: &alwaysRefs, unknown: &unknownRefs)
                case .min(let e, _): collectTableRefs(e, into: &alwaysRefs, unknown: &unknownRefs)
                case .avg(let e): collectTableRefs(e, into: &alwaysRefs, unknown: &unknownRefs)
                case .custom(_, let args):
                    for arg in args { collectTableRefs(arg, into: &alwaysRefs, unknown: &unknownRefs) }
            }
        }
        collectAccessRefs(clauses.leadingAccess, into: &alwaysRefs, unknown: &unknownRefs)
        for acc in clauses.boundJoinAccess { collectAccessRefs(acc, into: &alwaysRefs, unknown: &unknownRefs) }
        var onRefs: [Set<Int>] = []
        for on in clauses.joinsOn {
            var refs: Set<Int> = []
            collectTableRefs(on, into: &refs, unknown: &unknownRefs)
            onRefs.append(refs)
        }
        let existenceOnly: [Bool] = joins.indices.map { d in
            guard !unknownRefs, joinProbeCoversON[d] else { return false }
            let table = joins[d].table
            if alwaysRefs.contains(table) { return false }
            for e in joins.indices where e != d && onRefs[e].contains(table) { return false }
            return true
        }
        var finalRefs: Set<Int> = []
        var finalUnknown = false
        for o in clauses.outputs { collectTableRefs(o.expr, into: &finalRefs, unknown: &finalUnknown) }
        if let h = clauses.having { collectTableRefs(h, into: &finalRefs, unknown: &finalUnknown) }
        for t in clauses.orderBy { collectTableRefs(t.expr, into: &finalRefs, unknown: &finalUnknown) }
        let finalizationReferenced: Set<Int> = finalUnknown ? Set(0 ..< tableCount) : finalRefs
        return RefAnalysis(
            existenceOnly: existenceOnly, finalizationReferenced: finalizationReferenced,
            unknownRefs: unknownRefs)
    }

    /// Covering / INCLUDE-index rewrite: when the leading access is an index scan and
    /// every base-table column still needed is served by that index (rowid-alias from
    /// the key, or an INCLUDE column from the entry value), serve rows index-only.
    /// Gated (`enabled`) to the non-aggregated single-table path with no unresolved refs.
    static func applyCovering(
        leadingAccess: AccessPlan, clauses: BoundClauses, enabled: Bool,
        sourceIndexes: [IndexDefinition], source: TableBinding
    ) -> AccessPlan {
        guard enabled, case .index(let name, _, _, _) = leadingAccess,
            let definition = sourceIndexes.first(where: { $0.name == name })
        else { return leadingAccess }
        var requiredColumns: Set<Int> = []
        var requiredUnknown = false
        func need(_ e: SQLExpr) {
            collectColumnRefs(e, table: 0, into: &requiredColumns, unknown: &requiredUnknown)
        }
        for o in clauses.outputs { need(o.expr) }
        if let r = clauses.residual { need(r) }
        if let h = clauses.having { need(h) }
        for t in clauses.orderBy { need(t.expr) }
        for g in clauses.groupBy { need(g) }
        collectColumnRefs(
            forAccess: leadingAccess, table: 0, into: &requiredColumns, unknown: &requiredUnknown)
        var servable: Set<Int> = []
        if let alias = source.rowidAliasIndex { servable.insert(alias) }
        for column in definition.includes {
            if let index = source.columnIndex(qualifier: nil, name: column) { servable.insert(index) }
        }
        if !requiredUnknown, requiredColumns.isSubset(of: servable) {
            return coveringRewrite(leadingAccess, includes: definition.includes)
        }
        return leadingAccess
    }

    /// Index-ordered DISTINCT: a single-table `SELECT DISTINCT <plain cols>` with no
    /// WHERE/ORDER BY/aggregate can scan an index whose key columns are exactly those
    /// outputs (NOCASE-text excluded — case folds into the key). Returns its name, else nil.
    static func findDistinctIndex(
        select: SQLSelect, isAggregated: Bool, isJoin: Bool, source: TableBinding,
        outputs: [BoundOutput], sourceIndexes: [IndexDefinition]
    ) -> String? {
        guard select.distinct, !isAggregated, !isJoin, !source.isFTS,
            select.whereExpr == nil, select.orderBy.isEmpty
        else { return nil }
        var columnNames: [String] = []
        for out in outputs {
            guard case .column(let qualifier, let name, _) = out.expr,
                let column = source.columnIndex(qualifier: qualifier, name: name)
            else { return nil }
            if source.columnTypes[column] == .text, source.columnCollations[column] == .nocase {
                return nil  // NOCASE text decodes to folded bytes, not the original
            }
            columnNames.append(name)
        }
        guard !columnNames.isEmpty else { return nil }
        for candidate in sourceIndexes
        where candidate.columns.count == columnNames.count
            && zip(candidate.columns, columnNames).allSatisfy({ $0.lowercased() == $1.lowercased() })
        {
            return candidate.name
        }
        return nil
    }

    /// Everything the projection / source-planning / final column-binding phases
    /// produce that `bindSelect`'s late analysis + assembly still need.
    struct ClauseBindings {
        let binding: QueryBinding
        let outputs: [BoundOutput]
        let isAggregated: Bool
        let orderCollations: [Collation]
        let outputCollations: [Collation]
        let groupCollations: [Collation]
        let header: SQLColumnHeader
        let source: TableBinding
        let sourceIndexes: [IndexDefinition]
        let yieldsOrder: Bool
        let planning: AccessPlanning
        let mergePlan: MergePlan?
        let clauses: BoundClauses
    }

    /// Binds the projection (aggregate rewrite + output names + collations), plans the
    /// leading source's access path, then resolves every runtime column reference to
    /// `(table, column)` slots and applies the captured bm25 weights. Produces the
    /// fully-bound clauses + access plans the analysis passes consume.
    static func bindClauses(
        select: SQLSelect, schema: Schema, tables: [TableBinding], binding: QueryBinding,
        joins: [BoundJoin]
    ) throws(DBError) -> ClauseBindings {
        // Aggregate calls in outputs/HAVING/ORDER BY are rewritten to slot references;
        // `aggregates` collects the distinct ones to accumulate.
        var aggregates: [AggregateSpec] = []
        var outputs: [BoundOutput] = []
        for column in select.columns {
            switch column {
                case .star:
                    for table in tables { appendAllColumns(table, to: &outputs) }
                case .tableStar(let qualifier):
                    guard let table = tables.first(where: { $0.binding == qualifier.lowercased() }) else {
                        throw DBError.sqlBind("no such table alias: \(qualifier)")
                    }
                    appendAllColumns(table, to: &outputs)
                case .expr(let expr, let alias, let sourceText):
                    let rewritten = try rewriteAggregates(expr, into: &aggregates)
                    outputs.append(
                        BoundOutput(
                            name: outputName(expr, alias: alias, sourceText: sourceText), expr: rewritten))
            }
        }
        var having: SQLExpr?
        if let rawHaving = select.having {
            having = try rewriteAggregates(rawHaving, into: &aggregates)
        }
        // ORDER BY resolves a bare identifier against output aliases first (SQLite).
        var orderBy = select.orderBy
        for index in orderBy.indices {
            if case .column(nil, let name, _) = orderBy[index].expr,
                let match = outputs.first(where: { $0.name.lowercased() == name.lowercased() })
            {
                orderBy[index].expr = match.expr  // already aggregate-rewritten
            } else {
                orderBy[index].expr = try rewriteAggregates(orderBy[index].expr, into: &aggregates)
            }
        }
        let isAggregated = !select.groupBy.isEmpty || !aggregates.isEmpty
        let orderCollations = orderBy.map { collation(of: $0.expr, binding: binding) }
        let outputCollations = outputs.map { collation(of: $0.expr, binding: binding) }
        let groupCollations = select.groupBy.map { collation(of: $0, binding: binding) }
        let header = SQLColumnHeader(outputs.map(\.name))

        // Source access planning (outer table only; aggregated scans every row). A
        // leading-FTS MATCH conjunct is an access path the `.fts` source consumes —
        // strip it from the residual WHERE on every path.
        let source = tables[0]
        let sourceDefinition =
            source.isFTS ? syntheticFTSDefinition(source.table) : schema.tables[source.table]!
        let sourceIndexes = source.isFTS ? [] : schema.indexes(on: source.table)
        let planning = Planner.plan(
            where: select.whereExpr, orderBy: select.orderBy, source: source,
            indexes: sourceIndexes, definition: sourceDefinition)
        let yieldsOrder = joins.isEmpty && !isAggregated
        var whereExpr = select.whereExpr
        if case .fts = planning.plan {
            whereExpr = removeCovered(whereExpr, planning.coveredConjuncts)
        }
        let residualWithoutCovered =
            yieldsOrder ? removeCovered(whereExpr, planning.coveredConjuncts) : whereExpr

        // Resolve every runtime column reference to a slot; the same pass intercepts
        // `bm25(…)`/`rank` and captures per-column weights, applied to the access below.
        var ftsWeights: [Int: [Double]] = [:]
        func bind(_ expr: SQLExpr) -> SQLExpr { bindColumns(expr, binding, &ftsWeights) }
        // Bind every expression FIRST so the bm25-weight capture (`ftsWeights`) is
        // complete before it is applied to the access plans below.
        let boundOutputs = outputs.map { BoundOutput(name: $0.name, expr: bind($0.expr)) }
        let boundWhere = whereExpr.map(bind)
        let boundResidual = residualWithoutCovered.map(bind)
        let boundOrderBy = orderBy.map { SQLOrderingTerm(expr: bind($0.expr), descending: $0.descending) }
        let boundGroupBy = select.groupBy.map(bind)
        let boundHaving = having.map(bind)
        let boundAggregates = aggregates.map { bindAggregate($0, binding) }
        let boundJoinsOn = joins.map { bind($0.on) }
        let leadingAccess = bindAccess(applyWeights(planning.plan, ftsWeights, depth: 0), binding)
        let boundJoinAccess = joins.map {
            bindAccess(applyWeights($0.access, ftsWeights, depth: $0.table), binding)
        }
        return ClauseBindings(
            binding: binding, outputs: outputs, isAggregated: isAggregated,
            orderCollations: orderCollations, outputCollations: outputCollations,
            groupCollations: groupCollations, header: header, source: source,
            sourceIndexes: sourceIndexes, yieldsOrder: yieldsOrder, planning: planning,
            mergePlan: mergeJoinPlan(joins: joins, boundOn: boundJoinsOn, binding: binding, schema: schema),
            clauses: BoundClauses(
                outputs: boundOutputs, whereExpr: boundWhere, residual: boundResidual,
                orderBy: boundOrderBy, groupBy: boundGroupBy, having: boundHaving,
                aggregates: boundAggregates, joinsOn: boundJoinsOn,
                leadingAccess: leadingAccess, boundJoinAccess: boundJoinAccess))
    }

    /// Assembles the final `BoundSelect` from the bound clauses + the late analysis
    /// results (existence-only / finalization tables, covering-rewritten access, and
    /// the index-ordered-DISTINCT name).
    static func assemble(
        b: ClauseBindings, refs: RefAnalysis, joins: [BoundJoin], select: SQLSelect,
        leadingAccess: AccessPlan, distinctIndexName: String?
    ) -> BoundSelect {
        BoundSelect(
            binding: b.binding,
            joins: joins.indices.map { d in
                BoundJoin(
                    kind: joins[d].kind, table: joins[d].table, on: b.clauses.joinsOn[d],
                    access: b.clauses.boundJoinAccess[d], innerExistenceOnly: refs.existenceOnly[d])
            },
            outputs: b.clauses.outputs,
            outputCollations: b.outputCollations,
            whereExpr: b.clauses.whereExpr,
            residualWithoutCovered: b.clauses.residual,
            orderBy: b.clauses.orderBy,
            orderCollations: b.orderCollations,
            groupBy: b.clauses.groupBy,
            groupCollations: b.groupCollations,
            having: b.clauses.having,
            aggregates: b.clauses.aggregates,
            isAggregated: b.isAggregated,
            distinct: select.distinct,
            limit: select.limit,
            offset: select.offset,
            header: b.header,
            access: leadingAccess,
            accessYieldsOrder: b.yieldsOrder && b.planning.yieldsOrder,
            rowidOrderSatisfiesOrderBy: b.yieldsOrder && b.planning.rowidOrderSatisfiesOrderBy,
            finalizationReferencedTables: refs.finalizationReferenced,
            distinctIndexName: distinctIndexName,
            mergePlan: b.mergePlan)
    }
}
