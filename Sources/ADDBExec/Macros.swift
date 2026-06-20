@_spi(ADDBEngine) public import ADDBCore
import ADSQL
public import ADSQLModel

/// A Swift type that maps to a SQL table: its schema (`TableDefinition`) and a
/// way to materialize an instance from a result ``SQLRow``. `@Table` synthesizes
/// the conformance from a struct's stored properties.
public protocol TableRow {
    /// The table's schema — columns mirror the type's stored properties (Swift type
    /// → column affinity, an optional property → a nullable column), in declaration
    /// order.
    static var tableDefinition: TableDefinition { get }
    /// Builds an instance by decoding `row`'s values positionally (column *i* ←
    /// `row[i]`), throwing if a value's storage class doesn't match the property.
    init(row: SQLRow) throws(DBError)
}

/// Synthesizes ``TableRow`` conformance for a struct: a `TableDefinition` whose
/// columns mirror the stored properties and an `init(row:)` that decodes a
/// ``SQLRow``. The table name defaults to the type name; pass a string to override.
///
/// ```swift
/// @Table("users")
/// struct User {
///   let id: Int64
///   let name: String
///   let nickname: String?   // → a nullable TEXT column
/// }
/// ```
@attached(extension, conformances: TableRow, names: named(tableDefinition), named(init(row:)))
public macro Table(_ name: String? = nil) =
    #externalMacro(module: "ADSQLMacros", type: "TableMacro")

/// A compile-time-validated SQL string literal. `#SQL("SELECT …")` checks — purely
/// syntactically — that the literal is non-empty, has balanced parentheses and
/// quotes, and begins with a recognized SQL keyword, then expands to the string
/// unchanged. So `db.prepare(#SQL("SELECT * FROM users"))` rejects an obviously
/// malformed literal at build time while the engine's real parse still runs in
/// `prepare`.
///
/// Lightweight by design: it does not parse the full statement. The parser is
/// entangled with ADDBCore `Value`/`ColumnType`, which the macro plugin cannot
/// link, so a complete compile-time parse is out of scope.
///
/// ```swift
/// let rows = try db.prepare(#SQL("SELECT id, name FROM users WHERE id = ?")).all(.integer(1))
/// ```
@freestanding(expression)
public macro SQL(_ sql: String) -> String =
    #externalMacro(module: "ADSQLMacros", type: "SQLMacro")
