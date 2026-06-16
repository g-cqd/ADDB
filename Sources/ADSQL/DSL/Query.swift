import ADDBCore

/// Result builder that collects ``QueryComponent`` clauses, threading them in
/// source order (the RegexBuilder shape: `buildPartialBlock` accumulates), with
/// `if`/`switch`/`for` support.
@resultBuilder
public enum QueryBuilder {
    public static func buildExpression(_ component: some QueryComponent) -> [QueryComponent] {
        [component]
    }
    public static func buildPartialBlock(first: [QueryComponent]) -> [QueryComponent] { first }
    public static func buildPartialBlock(
        accumulated: [QueryComponent], next: [QueryComponent]
    ) -> [QueryComponent] {
        accumulated + next
    }
    public static func buildOptional(_ component: [QueryComponent]?) -> [QueryComponent] {
        component ?? []
    }
    public static func buildEither(first: [QueryComponent]) -> [QueryComponent] { first }
    public static func buildEither(second: [QueryComponent]) -> [QueryComponent] { second }
    public static func buildArray(_ components: [[QueryComponent]]) -> [QueryComponent] {
        components.flatMap { $0 }
    }
    public static func buildLimitedAvailability(_ component: [QueryComponent]) -> [QueryComponent] {
        component
    }
}

/// A SELECT query assembled from ``QueryComponent`` clauses. It lowers to the
/// engine's own `SQLSelect` AST, so binding, planning, and execution are the
/// proven string-SQL paths — the builder is a typed front door, not a second
/// engine.
///
/// ```swift
/// let rows = try Query {
///     Select("id", "title")
///     From("documents")
///     Where { $0.score > 2.0 }
///     OrderBy("title")
///     Limit(10)
/// }.all(on: db)
/// ```
public struct Query: Sendable {
    public let components: [QueryComponent]

    public init(components: [QueryComponent]) { self.components = components }
    public init(@QueryBuilder _ build: () -> [QueryComponent]) { components = build() }

    /// Lowers the clauses into a `SQLSelect` — the same AST the parser produces.
    /// An empty `SELECT` list defaults to `*`.
    public func makeSelect() -> SQLSelect {
        var select = SQLSelect()
        for component in components { component.apply(to: &select) }
        if select.columns.isEmpty { select.columns = [.star] }
        return select
    }
}

extension Query {
    /// Runs the query against `db` in a read snapshot, returning all result rows.
    public func all(on db: Database) throws(DBError) -> [SQLRow] {
        let select = makeSelect()
        let execution = db.options.execution
        return try db.read { (txn) throws(DBError) -> [SQLRow] in
            switch try Binder.bindQuery(select, schema: try txn.schema()) {
            case .select(let plan):
                return try Statement.runSelect(
                    plan, txn: txn, params: SQLParameters(), execution: execution)
            case .compound(let compound):
                return try Statement.runCompound(
                    compound, txn: txn, params: SQLParameters(), execution: execution)
            }
        }
    }

    /// The first result row, or nil when the query matches nothing.
    public func first(on db: Database) throws(DBError) -> SQLRow? {
        try all(on: db).first
    }
}

extension Database {
    /// Builds and runs a query inline: `try db.fetch { Select(…); From(…); … }`.
    public func fetch(@QueryBuilder _ build: () -> [QueryComponent]) throws(DBError) -> [SQLRow] {
        try Query(components: build()).all(on: self)
    }
}
