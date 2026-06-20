import ADSQL
@_spi(ADDBEngine) import ADSQLModel

/// ORDER BY analysis for the planner: whether an index scan or rowid order
/// satisfies the requested ordering. Split from `Planner.swift` to keep the
/// enum body within the gate.
extension Planner {
    // MARK: - Order analysis

    /// ORDER BY satisfied by index order: terms (after the consumed prefix
    /// columns) match the index columns in order, all ascending, with matching
    /// collations.
    static func indexYieldsOrder(
        _ orderBy: [SQLOrderingTerm], columns: [Int], prefixConsumed: Int,
        source: TableBinding, index: IndexDefinition, definition: TableDefinition
    ) -> Bool {
        guard !orderBy.isEmpty else { return true }
        guard let terms = orderColumns(orderBy, source: source) else { return false }
        guard prefixConsumed + terms.count <= columns.count else { return false }
        for (offset, term) in terms.enumerated() {
            let indexPosition = prefixConsumed + offset
            guard term.column == columns[indexPosition], !term.descending else { return false }
            let columnCollation = definition.columns[columns[indexPosition]].collation
            guard term.collation == columnCollation else { return false }
        }
        return true
    }

    static func rowidOrderSatisfies(_ orderBy: [SQLOrderingTerm], source: TableBinding) -> Bool {
        guard let aliasIndex = source.rowidAliasIndex else { return false }
        guard let terms = orderColumns(orderBy, source: source), terms.count == 1 else { return false }
        return terms[0].column == aliasIndex && !terms[0].descending
    }

    private struct OrderColumn {
        let column: Int
        let descending: Bool
        let collation: Collation
    }

    /// Order terms reduced to (column, direction, collation), or nil if any term
    /// is not a plain column reference.
    private static func orderColumns(
        _ orderBy: [SQLOrderingTerm], source: TableBinding
    ) -> [OrderColumn]? {
        var result: [OrderColumn] = []
        for term in orderBy {
            var expr = term.expr
            var collation: Collation?
            if case .collate(let inner, let explicit) = expr {
                expr = inner
                collation = explicit
            }
            guard case .column(let qualifier, let name, _) = expr,
                let column = source.columnIndex(qualifier: qualifier, name: name)
            else { return nil }
            result.append(
                OrderColumn(
                    column: column, descending: term.descending,
                    collation: collation ?? source.columnCollations[column]))
        }
        return result
    }
}
