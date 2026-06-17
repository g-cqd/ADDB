# The query DSL

Build reads, writes, and aggregates in type-safe Swift, validate them ahead of
execution, and decode results into typed rows.

## Overview

The DSL is a thin, typed front door over the SQL engine: a ``Query`` lowers to the
same `SQLSelect` the parser produces, and ``Insert`` / ``Update`` / ``Delete`` lower
to the same write AST the engine executes — so the builder reuses the proven
binding, planning, and index/foreign-key maintenance rather than adding a second
code path.

### Reading rows

A ``Query`` is a result builder of components. ``Select`` projects columns (by name
or via ``Column(_:)``), ``From`` names the table, and ``Where`` / ``OrderBy`` /
``Limit`` / ``Offset`` / ``Distinct`` shape the result. ``Query/all(on:)`` returns
every ``SQLRow``; ``Query/first(on:)`` returns the first.

```swift
let rows = try Query {
    Select("id", "name")
    From("users")
    Where { $0.name == "Ada" }
    OrderBy("id", .descending)
    Limit(10)
}.all(on: db)
```

The `Where { $0.name == "Ada" }` closure form receives a ``ColumnProxy`` whose
dynamic members are columns; `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||`, and
`like` / `notLike` build a ``Predicate``. A ``Predicate`` can also be written
directly against a ``Column(_:)``.

### Joins

``Join`` and ``LeftJoin`` take a join predicate; qualify columns with the
two-argument ``Column(_:_:)``.

```swift
let rows = try Query {
    Select(Column("users", "name"), Column("posts", "title"))
    From("users")
    Join("posts", on: Column("posts", "user_id") == Column("users", "id"))
}.all(on: db)
```

### Aggregates and grouping

``Count()`` (the row count), ``Count(_:)``, and ``Sum(_:)`` are projections;
``SQLProjection/as(_:)`` names the result column. Combine them with ``GroupBy`` and
``Having``.

```swift
let rows = try Query {
    Select(Column("kind"), Count().as("n"), Sum(Column("score")).as("total"))
    From("docs")
    GroupBy("kind")
    Having { $0.n > 1 }
}.all(on: db)
```

### Writing rows

``Insert``, ``Update``, and ``Delete`` lower to the engine's write AST and run inside
a single durable write transaction via `run(on:)`.

```swift
try Insert(into: "users", columns: ["id", "name"], values: [1, "Ada"]).run(on: db)
try Insert(into: "users", columns: ["id", "name"], rows: [[2, "Bo"], [3, "Cy"]])
    .orIgnore().run(on: db)

try Update("users").set("name", to: "Ada Lovelace").where { $0.id == 1 }.run(on: db)
try Delete(from: "users").where { $0.id == 3 }.run(on: db)
```

### Validating ahead of execution

`validate(against:)` binds the query against the live schema and throws a
``SQLBuildError`` for an unknown table, unknown column, or type mismatch — without
executing it, so a builder can fail early with a precise message.

```swift
do {
    try query.validate(against: db)
} catch let error as SQLBuildError {
    print(error)   // e.g. no such table: ghosts
}
```

### Typed rows with `@Table`

Apply ``Table(_:)`` to a struct of stored properties to synthesize a ``TableRow``
conformance: a `tableDefinition` (columns and types inferred from the properties)
and an `init(row:)` that decodes an ``SQLRow``. ``Query/all(on:as:)`` and
``Query/first(on:as:)`` then return typed values.

```swift
@Table("users")
struct User {
    let id: Int64
    let name: String
    let nickname: String?
}

try db.writeSync { (txn) throws(DBError) in try txn.createTable(User.tableDefinition) }

let users = try Query {
    Select("id", "name", "nickname")
    From("users")
    OrderBy("id")
}.all(on: db, as: User.self)
```

An optional property becomes a nullable column; a non-optional becomes `NOT NULL`.
`Int64` / `String` / `Double` / `Bool` / `[UInt8]` map to `INTEGER` / `TEXT` /
`REAL` / `INTEGER` / `BLOB`.

### Compile-time checks with `#SQL`

``SQL(_:)`` performs lightweight compile-time validation of a raw statement —
non-empty, balanced quotes and parentheses, and a recognized leading keyword — and
emits the checked string. A malformed literal is a compile error, not a runtime
failure.

```swift
let stmt = try db.prepare(#SQL("SELECT id, name FROM users WHERE id = ?"))
// #SQL("SELECT (1")  → compile error: unbalanced parentheses
// #SQL("FOO bar")    → compile error: unrecognized leading keyword
```

Full compile-time parsing is out of scope: `#SQL` is a guardrail against obvious
typos, not a substitute for `validate(against:)` against a real schema.
