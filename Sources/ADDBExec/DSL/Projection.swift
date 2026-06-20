@_spi(ADDBEngine) public import ADDBCore
import ADSQL
import ADSQLModel

/// A single item in a `Select` list: an expression (column, aggregate, …) plus an
/// optional alias. Build one from a column name, a ``SQLColumn``, or an aggregate
/// helper (``Count()``/``Sum(_:)``), and alias it with ``as(_:)``.
public struct SQLProjection: Sendable {
    var column: SQLResultColumn

    init(_ expr: SQLExpr, sourceText: String) {
        column = .expr(expr, alias: nil, sourceText: sourceText)
    }

    /// `<expr> AS <alias>`.
    public func `as`(_ alias: String) -> SQLProjection {
        guard case .expr(let expr, _, let sourceText) = column else { return self }
        var copy = self
        copy.column = .expr(expr, alias: alias, sourceText: sourceText)
        return copy
    }
}

/// Anything usable as a `Select` item: a bare column name, a ``SQLColumn``, an
/// aggregate (``SQLProjection``), so a single `Select(…)` can mix them
/// (`Select(Column("kind"), Count().as("n"))`).
public protocol SQLProjectionConvertible: Sendable {
    var sqlProjection: SQLProjection { get }
}

extension SQLProjection: SQLProjectionConvertible {
    public var sqlProjection: SQLProjection { self }
}
extension String: SQLProjectionConvertible {
    public var sqlProjection: SQLProjection {
        SQLProjection(.column(table: nil, name: self, offset: 0), sourceText: self)
    }
}
extension SQLColumn: SQLProjectionConvertible {
    public var sqlProjection: SQLProjection {
        SQLProjection(sqlExpression, sourceText: name)
    }
}

// MARK: - Aggregate helpers

/// `COUNT(*)`.
public func Count() -> SQLProjection {
    SQLProjection(.function(name: "COUNT", args: [], star: true, offset: 0), sourceText: "count(*)")
}
/// `COUNT(<column>)`.
public func Count(_ column: SQLColumn) -> SQLProjection {
    SQLProjection(
        .function(name: "COUNT", args: [column.sqlExpression], star: false, offset: 0),
        sourceText: "count(\(column.name))")
}
/// `SUM(<column>)`.
public func Sum(_ column: SQLColumn) -> SQLProjection {
    SQLProjection(
        .function(name: "SUM", args: [column.sqlExpression], star: false, offset: 0),
        sourceText: "sum(\(column.name))")
}
