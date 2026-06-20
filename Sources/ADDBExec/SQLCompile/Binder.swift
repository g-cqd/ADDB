import ADSQL
@_spi(ADDBEngine) import ADSQLModel

/// Public validation entry: binds `select` against `schema` purely to surface the
/// binder's semantic checks (table/column resolution, aggregate rules, collations)
/// as a typed `DBError`, discarding the bound plan. Lets the builder DSL's
/// `validate(against:)` fail early without exposing `Binder`/`BoundQuery`.
func validateQuery(_ select: SQLSelect, schema: Schema) throws(DBError) {
    _ = try Binder.bindQuery(select, schema: schema)
}

/// The binder: turns a parsed `SQLSelect` into a `BoundSelect`/`BoundQuery`
/// (the abstract syntax resolved against a concrete schema version), including
/// access selection, join-equality analysis, aggregate rewriting, and column
/// binding. The bound-plan data types it produces live in `Plan.swift`.
enum Binder {
    /// Maximum number of arms in one compound SELECT (`A UNION B UNION …`), mirroring SQLite's
    /// `SQLITE_LIMIT_COMPOUND_SELECT` (default 500). Without it a pathological compound chain would
    /// bind every arm unbounded; the cap surfaces a typed `DBError` instead. Same bounded-idiom as
    /// `SQLTriggerEngine.maxDepth` (100) and `JoinExecutor.maxJoinTables` (64).
    static let maxCompoundDepth = 500

    /// Binds a top-level query: a single SELECT or a compound. The trailing
    /// ORDER BY/LIMIT/OFFSET on a compound belong to the whole result, so the
    /// first arm is bound without them.
    static func bindQuery(_ select: SQLSelect, schema: Schema) throws(DBError) -> BoundQuery {
        guard !select.compounds.isEmpty else {
            return .select(try bindSelect(select, schema: schema))
        }
        guard select.compounds.count <= Self.maxCompoundDepth else {
            throw DBError.sqlBind(
                "compound SELECT has too many terms (\(select.compounds.count) > \(Self.maxCompoundDepth))")
        }
        var firstArm = select
        firstArm.compounds = []
        firstArm.orderBy = []
        firstArm.limit = nil
        firstArm.offset = nil
        var arms: [BoundCompound.Arm] = [
            BoundCompound.Arm(op: nil, select: try bindSelect(firstArm, schema: schema))
        ]
        for compound in select.compounds {
            arms.append(
                BoundCompound.Arm(op: compound.op, select: try bindSelect(compound.select, schema: schema)))
        }
        let width = arms[0].select.outputs.count
        for arm in arms where arm.select.outputs.count != width {
            throw DBError.sqlBind("SELECTs to the left and right of a compound have different column counts")
        }
        let first = arms[0].select
        var order: [BoundCompound.CompoundOrder] = []
        for term in select.orderBy {
            order.append(
                try resolveCompoundOrder(term, outputs: first.outputs, collations: first.outputCollations))
        }
        return .compound(
            BoundCompound(
                arms: arms, header: first.header, outputCollations: first.outputCollations,
                order: order, limit: select.limit, offset: select.offset))
    }

    /// A compound ORDER BY term references a result column by 1-based position
    /// or by name (SQLite restriction).
    private static func resolveCompoundOrder(
        _ term: SQLOrderingTerm, outputs: [BoundOutput], collations: [Collation]
    ) throws(DBError) -> BoundCompound.CompoundOrder {
        var expr = term.expr
        var explicit: Collation?
        if case .collate(let inner, let collation) = expr {
            expr = inner
            explicit = collation
        }
        let index: Int
        switch expr {
            case .literal(.integer(let position)):
                guard position >= 1, position <= outputs.count else {
                    throw DBError.sqlBind("ORDER BY position \(position) is out of range")
                }
                index = Int(position) - 1
            case .column(nil, let name, _):
                guard let match = outputs.firstIndex(where: { $0.name.lowercased() == name.lowercased() })
                else {
                    throw DBError.sqlBind("ORDER BY \(name) is not a column of the compound result")
                }
                index = match
            default:
                throw DBError.sqlUnsupported("compound ORDER BY must name a result column or position")
        }
        return BoundCompound.CompoundOrder(
            index: index, descending: term.descending, collation: explicit ?? collations[index])
    }

    static func bindSelect(_ select: SQLSelect, schema: Schema) throws(DBError) -> BoundSelect {
        guard let from = select.from else {
            throw DBError.sqlUnsupported("SELECT without FROM (arrives in a later slice)")
        }

        // Resolve every table in FROM/JOIN order; the first is the outer table. An
        // FTS5 virtual table isn't in `schema.tables`; it binds against a synthetic
        // rowid-alias definition (its only queryable column is `rowid`; the indexed
        // text is reached through MATCH, not column reads).
        func bind(_ reference: SQLTableRef) throws(DBError) -> TableBinding {
            if let definition = schema.tables[reference.name] {
                return TableBinding(reference: reference, definition: definition)
            }
            if schema.ftsTables[reference.name] != nil {
                return TableBinding(
                    reference: reference, definition: syntheticFTSDefinition(reference.name), isFTS: true)
            }
            throw DBError.noSuchTable(reference.name)
        }
        var tables: [TableBinding] = [try bind(from)]
        var rawJoins: [(kind: SQLJoinKind, depth: Int, on: SQLExpr)] = []
        for join in select.joins {
            tables.append(try bind(join.table))
            rawJoins.append((join.kind, tables.count - 1, join.on))
        }
        let binding = QueryBinding(tables: tables)

        // Index-nested-loop access per inner table (each ON re-applied at the leaf,
        // FTS-consumed MATCH conjuncts stripped); see `planJoins`.
        let (joins, joinProbeCoversON) = try planJoins(
            rawJoins: rawJoins, tables: tables, binding: binding, schema: schema)

        // Projection (aggregate rewrite + names + collations), source access planning,
        // and the final column-reference + bm25-weight binding pass; see `bindClauses`.
        let b = try bindClauses(
            select: select, schema: schema, tables: tables, binding: binding, joins: joins)

        // Column-reference analysis → existence-only inners + finalization tables.
        let refs = analyzeRefs(
            clauses: b.clauses, joins: joins, joinProbeCoversON: joinProbeCoversON,
            tableCount: tables.count)
        // Covering / INCLUDE-index serving (gated to the single-table, non-aggregated,
        // no-unresolved-refs path).
        let leadingAccess = applyCovering(
            leadingAccess: b.clauses.leadingAccess, clauses: b.clauses,
            enabled: !b.isAggregated && joins.isEmpty && !refs.unknownRefs,
            sourceIndexes: b.sourceIndexes, source: b.source)
        // Index-ordered DISTINCT (single-table, no WHERE/ORDER BY/aggregate).
        let distinctIndexName = findDistinctIndex(
            select: select, isAggregated: b.isAggregated, isJoin: !joins.isEmpty, source: b.source,
            outputs: b.outputs, sourceIndexes: b.sourceIndexes)
        return assemble(
            b: b, refs: refs, joins: joins, select: select, leadingAccess: leadingAccess,
            distinctIndexName: distinctIndexName)
    }
}
