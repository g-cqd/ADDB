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
