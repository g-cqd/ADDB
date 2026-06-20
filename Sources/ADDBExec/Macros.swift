public import ADSQLModel

/// A Swift type that maps to a SQL table: its schema (`TableDefinition`) and a
/// way to materialize an instance from a result ``SQLRow``. The `@Table` macro
/// (in the `ADDBMacros` layer) synthesizes the conformance from a struct's stored
/// properties; this protocol lives beside the executor so the typed query DSL
/// (`Query.all(on:as:)`) can decode result rows without depending on the macro.
public protocol TableRow {
    /// The table's schema — columns mirror the type's stored properties (Swift type
    /// → column affinity, an optional property → a nullable column), in declaration
    /// order.
    static var tableDefinition: TableDefinition { get }
    /// Builds an instance by decoding `row`'s values positionally (column *i* ←
    /// `row[i]`), throwing if a value's storage class doesn't match the property.
    init(row: SQLRow) throws(DBError)
}
