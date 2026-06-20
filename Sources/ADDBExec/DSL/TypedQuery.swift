@_spi(ADDBEngine) public import ADDBCore
import ADSQL
public import ADSQLModel

extension Query {
    /// Runs the query and decodes each result row into `Row` via its
    /// `@Table`-synthesized ``TableRow/init(row:)``. The query's `SELECT` list must
    /// produce the row type's columns in declaration order (e.g. `Select.all` over
    /// the table, or the columns in `tableDefinition` order).
    ///
    /// ```swift
    /// let users = try Query { Select.all; From("users") }.all(on: db, as: User.self)
    /// ```
    public func all<Row: TableRow>(on db: Database, as type: Row.Type) throws(DBError) -> [Row] {
        try all(on: db).map { (row) throws(DBError) in try Row(row: row) }
    }

    /// The first result row decoded into `Row`, or nil when the query matches nothing.
    public func first<Row: TableRow>(on db: Database, as type: Row.Type) throws(DBError) -> Row? {
        guard let row = try first(on: db) else { return nil }
        return try Row(row: row)
    }
}

extension Database {
    /// Builds, runs, and decodes a query into `Row` in one call.
    public func fetch<Row: TableRow>(
        _ type: Row.Type, @QueryBuilder _ build: () -> [any QueryComponent]
    ) throws(DBError) -> [Row] {
        try Query(components: build()).all(on: self, as: type)
    }
}
