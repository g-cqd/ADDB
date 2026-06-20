import ADSQL
@_spi(ADDBEngine) import ADSQLModel

/// Binder support: merge-join eligibility, table/column/access reference
/// collectors, covering-index rewrite, FTS weight application, and column
/// binding. Split from `Binder.swift` to keep the enum body within the gate.
extension Binder {
    /// A 2-table INNER equi-join whose join-key columns each have a UNIQUE,
    /// NOT-NULL, single-column index of the same collation → merge-eligible (the
    /// executor lock-steps the two sorted indexes under `.merge`/`.auto`). nil
    /// otherwise (the proven nested-loop / hash paths handle every other shape).
    static func mergeJoinPlan(
        joins: [BoundJoin], boundOn: [SQLExpr], binding: QueryBinding, schema: Schema
    ) -> MergePlan? {
        guard joins.count == 1, joins[0].kind == .inner, binding.tables.count == 2,
            !binding.tables[0].isFTS, !binding.tables[1].isFTS,
            case .binary(.eq, let lhs, let rhs) = boundOn[0]
        else { return nil }
        func cols(_ a: SQLExpr, _ b: SQLExpr) -> (outer: Int, inner: Int)? {
            guard case .boundColumn(let at, let ac) = a, case .boundColumn(let bt, let bc) = b,
                at == 0, bt == 1
            else { return nil }
            return (ac, bc)
        }
        guard let (oc, ic) = cols(lhs, rhs) ?? cols(rhs, lhs),
            binding.tables[0].columnCollations[oc] == binding.tables[1].columnCollations[ic],
            let outerIndex = uniqueKeyIndex(binding.tables[0], column: oc, schema: schema),
            let innerIndex = uniqueKeyIndex(binding.tables[1], column: ic, schema: schema)
        else { return nil }
        return MergePlan(
            outerIndex: outerIndex, innerIndex: innerIndex, outerColumn: oc, innerColumn: ic)
    }

    /// The name of a UNIQUE, single-column index on `column` of `table` whose
    /// column is NOT NULL (so no NULL keys break the merge lock-step), else nil.
    private static func uniqueKeyIndex(
        _ table: TableBinding, column: Int, schema: Schema
    ) -> String? {
        guard let definition = schema.tables[table.table], column < definition.columns.count,
            definition.columns[column].notNull
        else { return nil }
        let columnName = table.columnNames[column].lowercased()
        for index in schema.indexes(on: table.table)
        where index.unique && index.columns.count == 1
            && index.columns[0].lowercased() == columnName
        {
            return index.name
        }
        return nil
    }

    /// Adds the `(table)` of every `.boundColumn` in `expr` to `refs`. Sets
    /// `unknown` for an unresolved/correlated `.column` or a scalar subquery, whose
    /// reachable columns can't be determined here (callers then disable the
    /// reference-driven elisions). Covers every `SQLExpr` case.
    static func collectTableRefs(
        _ expr: SQLExpr, into refs: inout Set<Int>, unknown: inout Bool
    ) {
        // Iterative worklist: a deep operator chain cannot overflow. Order is
        // irrelevant — the result is set accumulation over every reachable leaf.
        var stack: [SQLExpr] = [expr]
        while let e = stack.popLast() {
            switch e {
                case .boundColumn(let table, _):
                    refs.insert(table)
                case .column, .scalarSubquery:
                    unknown = true
                case .literal, .parameter, .aggregateResult:
                    break
                case .binary(_, let l, let r):
                    stack.append(l)
                    stack.append(r)
                case .unary(_, let i), .cast(let i, _), .collate(let i, _):
                    stack.append(i)
                case .isNull(let i, _):
                    stack.append(i)
                case .like(let s, let p, _):
                    stack.append(s)
                    stack.append(p)
                case .inList(let s, let items, _):
                    stack.append(s)
                    stack.append(contentsOf: items)
                case .inJSONEach(let s, let src, _):
                    stack.append(s)
                    stack.append(src)
                case .caseWhen(let operand, let whens, let elseExpr):
                    if let operand { stack.append(operand) }
                    for when in whens {
                        stack.append(when.condition)
                        stack.append(when.result)
                    }
                    if let elseExpr { stack.append(elseExpr) }
                case .function(_, let args, _, _):
                    stack.append(contentsOf: args)
            }
        }
    }

    /// Adds the tables referenced by an access path's probe/rowid/MATCH value
    /// expressions (evaluated per outer row for a join inner).
    static func collectAccessRefs(
        _ access: AccessPlan, into refs: inout Set<Int>, unknown: inout Bool
    ) {
        switch access {
            case .tableScan:
                break
            case .rowid(let exprs):
                for e in exprs { collectTableRefs(e, into: &refs, unknown: &unknown) }
            case .index(_, let probes, _, _):
                for probe in probes {
                    for e in probe.equality { collectTableRefs(e, into: &refs, unknown: &unknown) }
                    if case .range(let lower, let upper)? = probe.trailing {
                        if let lower { collectTableRefs(lower.expr, into: &refs, unknown: &unknown) }
                        if let upper { collectTableRefs(upper.expr, into: &refs, unknown: &unknown) }
                    }
                }
            case .fts(_, let query, _):
                collectTableRefs(query, into: &refs, unknown: &unknown)
        }
    }

    /// Adds the COLUMN indices of `table` that `expr` reads to `columns` (
    /// covering analysis — the per-table refinement of `collectTableRefs`). Sets
    /// `unknown` for an unresolved/correlated `.column` or a scalar subquery, whose
    /// reachable columns can't be determined here (the caller then refuses to claim
    /// covering). Walks EVERY `SQLExpr` case — the safety of index-only serving rests
    /// on this never missing a base-table column reference, so it mirrors
    /// `collectTableRefs` exactly and adds no early-out.
    static func collectColumnRefs(
        _ expr: SQLExpr, table: Int, into columns: inout Set<Int>, unknown: inout Bool
    ) {
        // Iterative worklist mirroring `collectTableRefs`: a deep operator chain
        // cannot overflow, and it still visits every reachable leaf (no early-out),
        // so index-only covering analysis can never under-count a column reference.
        var stack: [SQLExpr] = [expr]
        while let e = stack.popLast() {
            switch e {
                case .boundColumn(let t, let c):
                    if t == table { columns.insert(c) }
                case .column, .scalarSubquery:
                    unknown = true
                case .literal, .parameter, .aggregateResult:
                    break
                case .binary(_, let l, let r):
                    stack.append(l)
                    stack.append(r)
                case .unary(_, let i), .cast(let i, _), .collate(let i, _):
                    stack.append(i)
                case .isNull(let i, _):
                    stack.append(i)
                case .like(let s, let p, _):
                    stack.append(s)
                    stack.append(p)
                case .inList(let s, let items, _):
                    stack.append(s)
                    stack.append(contentsOf: items)
                case .inJSONEach(let s, let src, _):
                    stack.append(s)
                    stack.append(src)
                case .caseWhen(let operand, let whens, let elseExpr):
                    if let operand { stack.append(operand) }
                    for when in whens {
                        stack.append(when.condition)
                        stack.append(when.result)
                    }
                    if let elseExpr { stack.append(elseExpr) }
                case .function(_, let args, _, _):
                    stack.append(contentsOf: args)
            }
        }
    }

    /// Folds an access path's probe/rowid value expressions into the per-table
    /// column set (the column-level analogue of `collectAccessRefs`). Probe values
    /// are constants/parameters in practice; included defensively so a future probe
    /// shape can never under-count the columns an index-only scan must serve.
    static func collectColumnRefs(
        forAccess access: AccessPlan, table: Int, into columns: inout Set<Int>, unknown: inout Bool
    ) {
        switch access {
            case .tableScan:
                break
            case .rowid(let exprs):
                for e in exprs { collectColumnRefs(e, table: table, into: &columns, unknown: &unknown) }
            case .index(_, let probes, _, _):
                for probe in probes {
                    for e in probe.equality { collectColumnRefs(e, table: table, into: &columns, unknown: &unknown) }
                    if case .range(let lower, let upper)? = probe.trailing {
                        if let lower { collectColumnRefs(lower.expr, table: table, into: &columns, unknown: &unknown) }
                        if let upper { collectColumnRefs(upper.expr, table: table, into: &columns, unknown: &unknown) }
                    }
                }
            case .fts(_, let query, _):
                collectColumnRefs(query, table: table, into: &columns, unknown: &unknown)
        }
    }

    /// Stamps an `.index` access plan as covering, attaching the index's FULL
    /// INCLUDE list (the entry-value layout the index-only decoder walks). A no-op
    /// for any non-`.index` plan.
    static func coveringRewrite(_ access: AccessPlan, includes: [String]) -> AccessPlan {
        guard case .index(let name, let probes, let constraint, _) = access else { return access }
        return .index(name: name, probes: probes, constraint: constraint, covering: includes)
    }

    /// An exact-equality probe — every matching row satisfies the covered ON
    /// equality exactly (no trailing range to re-check). `.tableScan`/`.fts` are
    /// supersets, so never exact.
    static func isExactEquality(_ access: AccessPlan) -> Bool {
        switch access {
            case .rowid:
                return true
            case .index(_, let probes, _, _):
                return !probes.isEmpty && probes.allSatisfy { $0.trailing == nil }
            case .tableScan, .fts:
                return false
        }
    }

    /// Overlays captured bm25 weights onto an `.fts` access plan for the table at
    /// `depth`; other plans pass through. With no bm25 call the plan keeps the
    /// Planner's default (empty → all-ones at execution), i.e. plain `rank`.
    static func applyWeights(
        _ access: AccessPlan, _ weights: [Int: [Double]], depth: Int
    ) -> AccessPlan {
        guard case .fts(let table, let query, _) = access, let captured = weights[depth] else {
            return access
        }
        return .fts(table: table, query: query, weights: captured)
    }

    /// Resolves resolvable `.column` refs to `.boundColumn(table, column)` slots
    /// (leaving correlated outer refs as `.column`); does not descend into
    /// `.scalarSubquery` (bound independently when executed). A `bm25(tbl, …)`
    /// call is rewritten to a bound read of the table's `rank` score slot, with its
    /// weight literals captured into `weights` (keyed by the table's depth).
    ///
    /// This recursion mirrors the expression tree, whose height the parser caps at
    /// `Parser.maxExpressionTreeDepth` (256) before binding ever runs, so it is
    /// bounded and cannot be driven to a stack overflow by a crafted query.
    static func bindColumns(
        _ expr: SQLExpr, _ binding: QueryBinding, _ weights: inout [Int: [Double]]
    ) -> SQLExpr {
        switch expr {
            case .column(let qualifier, let name, _):
                if let (table, column) = binding.resolve(qualifier: qualifier, name: name) {
                    return .boundColumn(table: table, column: column)
                }
                return expr
            case .literal, .parameter, .aggregateResult, .boundColumn, .scalarSubquery:
                return expr
            case .binary(let op, let lhs, let rhs):
                return .binary(op, bindColumns(lhs, binding, &weights), bindColumns(rhs, binding, &weights))
            case .unary(let op, let inner):
                return .unary(op, bindColumns(inner, binding, &weights))
            case .like(let subject, let pattern, let negated):
                return .like(
                    bindColumns(subject, binding, &weights),
                    pattern: bindColumns(pattern, binding, &weights), negated: negated)
            case .isNull(let inner, let negated):
                return .isNull(bindColumns(inner, binding, &weights), negated: negated)
            case .inList(let subject, let items, let negated):
                return .inList(
                    bindColumns(subject, binding, &weights),
                    items.map { bindColumns($0, binding, &weights) }, negated: negated)
            case .inJSONEach(let subject, let source, let negated):
                return .inJSONEach(
                    bindColumns(subject, binding, &weights),
                    source: bindColumns(source, binding, &weights), negated: negated)
            case .caseWhen(let operand, let whens, let elseExpr):
                return .caseWhen(
                    operand: operand.map { bindColumns($0, binding, &weights) },
                    whens: whens.map {
                        SQLWhen(
                            condition: bindColumns($0.condition, binding, &weights),
                            result: bindColumns($0.result, binding, &weights))
                    },
                    elseExpr: elseExpr.map { bindColumns($0, binding, &weights) })
            case .function(let name, let args, let star, let offset):
                if name.uppercased() == "BM25", let bound = bindBM25(args, binding, &weights) {
                    return bound
                }
                return .function(
                    name: name, args: args.map { bindColumns($0, binding, &weights) }, star: star,
                    offset: offset)
            case .cast(let inner, let type):
                return .cast(bindColumns(inner, binding, &weights), type)
            case .collate(let inner, let collation):
                return .collate(bindColumns(inner, binding, &weights), collation)
        }
    }

    /// Binds `bm25(tbl, w0, w1, …)`: the first argument names the FTS table (its
    /// alias-or-name, parsed as a bare column ref), the rest are numeric weight
    /// literals. Returns a bound read of the table's `rank` slot and records the
    /// authored weights under the table's depth (the executor pads/truncates them
    /// to the real column count); nil if the first argument doesn't name an FTS
    /// table in this query (so the generic `.function` path reports the error).
    private static func bindBM25(
        _ args: [SQLExpr], _ binding: QueryBinding, _ weights: inout [Int: [Double]]
    ) -> SQLExpr? {
        guard let first = args.first, case .column(let qualifier, let name, _) = first else { return nil }
        let target = qualifier ?? name
        guard let depth = binding.tables.firstIndex(where: { $0.binding == target.lowercased() }),
            binding.tables[depth].isFTS
        else { return nil }
        // Capture the authored weights as written; missing args default to 1.0 and
        // the real per-column length is resolved at execution (the synthetic binding
        // only carries [rowid, rank], not the FTS table's real text columns).
        weights[depth] = args.dropFirst().map { numericLiteral($0) ?? 1.0 }
        return .boundColumn(table: depth, column: ftsRankSlot)
    }

    /// A numeric weight literal (integer or real); nil otherwise.
    private static func numericLiteral(_ expr: SQLExpr) -> Double? {
        switch expr {
            case .literal(.integer(let value)): return Double(value)
            case .literal(.real(let value)): return value
            case .unary(.negate, let inner): return numericLiteral(inner).map { -$0 }
            default: return nil
        }
    }
}
