@_spi(ADDBEngine) import ADDBCore
public import ADSQL
public import ADSQLModel

/// A value usable as a scalar inside the query DSL — a column, a literal Swift
/// value, or an already-built ``SQLExpr``. The operators below build predicates
/// and expressions from these, mirroring SQL's own comparison/logical verbs.
public protocol SQLExpressionConvertible {
    /// The lowered expression node.
    var sqlExpression: SQLExpr { get }
}

extension SQLExpr: SQLExpressionConvertible {
    public var sqlExpression: SQLExpr { self }
}
extension Value: SQLExpressionConvertible {
    public var sqlExpression: SQLExpr { .literal(self) }
}
extension Int: SQLExpressionConvertible {
    public var sqlExpression: SQLExpr { .literal(.integer(Int64(self))) }
}
extension Int64: SQLExpressionConvertible {
    public var sqlExpression: SQLExpr { .literal(.integer(self)) }
}
extension Double: SQLExpressionConvertible {
    public var sqlExpression: SQLExpr { .literal(.real(self)) }
}
extension String: SQLExpressionConvertible {
    public var sqlExpression: SQLExpr { .literal(.text(self)) }
}
extension Bool: SQLExpressionConvertible {
    // SQLite has no boolean storage class; true/false are 1/0.
    public var sqlExpression: SQLExpr { .literal(.integer(self ? 1 : 0)) }
}

/// A column reference: a bare name, or `table.column`. Build one with
/// ``Column(_:)``/``Column(_:_:)``, or via a ``ColumnProxy`` (`$0.title`).
public struct SQLColumn: SQLExpressionConvertible, Sendable {
    public var table: String?
    public var name: String

    public init(_ name: String) {
        self.table = nil
        self.name = name
    }

    public init(_ table: String, _ name: String) {
        self.table = table
        self.name = name
    }

    public var sqlExpression: SQLExpr { .column(table: table, name: name, offset: 0) }
}

/// `Column("title")` or `Column("d", "title")` — a column reference for the DSL.
public func Column(_ name: String) -> SQLColumn { SQLColumn(name) }
public func Column(_ table: String, _ name: String) -> SQLColumn { SQLColumn(table, name) }

/// A `@dynamicMemberLookup` proxy so a predicate closure can name columns as
/// members: `Where { $0.score > 2 }` yields `SQLColumn("score")` for `$0.score`.
@dynamicMemberLookup
public struct ColumnProxy: Sendable {
    public init() {}
    public subscript(dynamicMember name: String) -> SQLColumn { SQLColumn(name) }
}

/// A boolean condition for `WHERE`/`HAVING`/`ON`, built from the comparison and
/// logical operators below. Wraps the lowered ``SQLExpr``.
public struct Predicate: SQLExpressionConvertible, Sendable {
    public var expression: SQLExpr
    public init(_ expression: SQLExpr) { self.expression = expression }
    public var sqlExpression: SQLExpr { expression }
}

// MARK: - Comparison operators (column OP value / column OP column)

private func compare(
    _ op: SQLBinaryOp, _ lhs: SQLColumn, _ rhs: some SQLExpressionConvertible
) -> Predicate {
    Predicate(.binary(op, lhs.sqlExpression, rhs.sqlExpression))
}

public func == (lhs: SQLColumn, rhs: some SQLExpressionConvertible) -> Predicate { compare(.eq, lhs, rhs) }
public func != (lhs: SQLColumn, rhs: some SQLExpressionConvertible) -> Predicate { compare(.ne, lhs, rhs) }
public func < (lhs: SQLColumn, rhs: some SQLExpressionConvertible) -> Predicate { compare(.lt, lhs, rhs) }
public func <= (lhs: SQLColumn, rhs: some SQLExpressionConvertible) -> Predicate { compare(.le, lhs, rhs) }
public func > (lhs: SQLColumn, rhs: some SQLExpressionConvertible) -> Predicate { compare(.gt, lhs, rhs) }
public func >= (lhs: SQLColumn, rhs: some SQLExpressionConvertible) -> Predicate { compare(.ge, lhs, rhs) }

// MARK: - Logical combinators

public func && (lhs: Predicate, rhs: Predicate) -> Predicate {
    Predicate(.binary(.and, lhs.expression, rhs.expression))
}
public func || (lhs: Predicate, rhs: Predicate) -> Predicate {
    Predicate(.binary(.or, lhs.expression, rhs.expression))
}
public prefix func ! (operand: Predicate) -> Predicate {
    Predicate(.unary(.not, operand.expression))
}

// MARK: - Column predicates (LIKE / IS NULL / IN / MATCH)

extension SQLColumn {
    public func like(_ pattern: String) -> Predicate {
        Predicate(.like(sqlExpression, pattern: .literal(.text(pattern)), negated: false))
    }
    public func notLike(_ pattern: String) -> Predicate {
        Predicate(.like(sqlExpression, pattern: .literal(.text(pattern)), negated: true))
    }
    public var isNull: Predicate { Predicate(.isNull(sqlExpression, negated: false)) }
    public var isNotNull: Predicate { Predicate(.isNull(sqlExpression, negated: true)) }
    public func `in`(_ values: [some SQLExpressionConvertible]) -> Predicate {
        Predicate(.inList(sqlExpression, values.map(\.sqlExpression), negated: false))
    }
    public func notIn(_ values: [some SQLExpressionConvertible]) -> Predicate {
        Predicate(.inList(sqlExpression, values.map(\.sqlExpression), negated: true))
    }
    /// FTS full-text membership: `<fts-table> MATCH <query>`.
    public func match(_ query: String) -> Predicate {
        Predicate(.binary(.match, sqlExpression, .literal(.text(query))))
    }
}
