import ADDBCore

/// One clause of a ``Query``. Each component contributes itself to the lowered
/// ``SQLSelect`` — the DSL is sugar over the same AST the parser produces, so it
/// reuses the binder, planner, and executor unchanged.
public protocol QueryComponent: Sendable {
    func apply(to select: inout SQLSelect)
}

/// `SELECT <columns>` — column names, ``SQLColumn``s, aggregates
/// (``Count()``/``Sum(_:)``), or ``Select/all`` for `*`. Items mix freely:
/// `Select(Column("kind"), Count().as("n"))`.
public struct Select: QueryComponent {
    let columns: [SQLResultColumn]

    public init(_ items: any SQLProjectionConvertible...) {
        columns = items.map { $0.sqlProjection.column }
    }
    private init(star: Void) { columns = [.star] }

    /// `SELECT *`.
    public static let all = Select(star: ())

    public func apply(to select: inout SQLSelect) { select.columns = columns }
}

/// `FROM <table> [AS alias]`.
public struct From: QueryComponent {
    let ref: SQLTableRef
    public init(_ table: String, as alias: String? = nil) {
        ref = SQLTableRef(name: table, alias: alias, offset: 0)
    }
    public func apply(to select: inout SQLSelect) { select.from = ref }
}

/// `INNER JOIN <table> ON <predicate>`.
public struct Join: QueryComponent {
    let join: SQLJoin
    public init(_ table: String, as alias: String? = nil, on predicate: Predicate) {
        join = SQLJoin(
            kind: .inner, table: SQLTableRef(name: table, alias: alias, offset: 0),
            on: predicate.expression)
    }
    public init(_ table: String, as alias: String? = nil, on build: (ColumnProxy) -> Predicate) {
        self.init(table, as: alias, on: build(ColumnProxy()))
    }
    public func apply(to select: inout SQLSelect) { select.joins.append(join) }
}

/// `LEFT JOIN <table> ON <predicate>`.
public struct LeftJoin: QueryComponent {
    let join: SQLJoin
    public init(_ table: String, as alias: String? = nil, on predicate: Predicate) {
        join = SQLJoin(
            kind: .left, table: SQLTableRef(name: table, alias: alias, offset: 0),
            on: predicate.expression)
    }
    public init(_ table: String, as alias: String? = nil, on build: (ColumnProxy) -> Predicate) {
        self.init(table, as: alias, on: build(ColumnProxy()))
    }
    public func apply(to select: inout SQLSelect) { select.joins.append(join) }
}

/// `WHERE <predicate>`. Repeated `Where` clauses are `AND`-combined.
public struct Where: QueryComponent {
    let predicate: Predicate
    public init(_ predicate: Predicate) { self.predicate = predicate }
    public init(_ build: (ColumnProxy) -> Predicate) { self.predicate = build(ColumnProxy()) }
    public func apply(to select: inout SQLSelect) {
        if let existing = select.whereExpr {
            select.whereExpr = .binary(.and, existing, predicate.expression)
        } else {
            select.whereExpr = predicate.expression
        }
    }
}

/// `GROUP BY <columns>`.
public struct GroupBy: QueryComponent {
    let exprs: [SQLExpr]
    public init(_ names: String...) {
        exprs = names.map { .column(table: nil, name: $0, offset: 0) }
    }
    public init(_ columns: SQLColumn...) { exprs = columns.map(\.sqlExpression) }
    public func apply(to select: inout SQLSelect) { select.groupBy += exprs }
}

/// `HAVING <predicate>`.
public struct Having: QueryComponent {
    let predicate: Predicate
    public init(_ predicate: Predicate) { self.predicate = predicate }
    public init(_ build: (ColumnProxy) -> Predicate) { self.predicate = build(ColumnProxy()) }
    public func apply(to select: inout SQLSelect) { select.having = predicate.expression }
}

/// Sort direction for ``OrderBy``.
public enum SortOrder: Sendable {
    case ascending
    case descending
}

/// `ORDER BY <column> [ASC|DESC]`. Repeated `OrderBy` clauses append terms.
public struct OrderBy: QueryComponent {
    let terms: [SQLOrderingTerm]
    public init(_ column: String, _ order: SortOrder = .ascending) {
        terms = [
            SQLOrderingTerm(
                expr: .column(table: nil, name: column, offset: 0), descending: order == .descending)
        ]
    }
    public init(_ column: SQLColumn, _ order: SortOrder = .ascending) {
        terms = [SQLOrderingTerm(expr: column.sqlExpression, descending: order == .descending)]
    }
    public func apply(to select: inout SQLSelect) { select.orderBy += terms }
}

/// `LIMIT <n>`.
public struct Limit: QueryComponent {
    let count: Int
    public init(_ count: Int) { self.count = count }
    public func apply(to select: inout SQLSelect) { select.limit = .literal(.integer(Int64(count))) }
}

/// `OFFSET <n>`.
public struct Offset: QueryComponent {
    let count: Int
    public init(_ count: Int) { self.count = count }
    public func apply(to select: inout SQLSelect) { select.offset = .literal(.integer(Int64(count))) }
}

/// `SELECT DISTINCT`.
public struct Distinct: QueryComponent {
    public init() {}
    public func apply(to select: inout SQLSelect) { select.distinct = true }
}
