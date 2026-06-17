# ``ADSQL``

A SQLite-compatible SQL layer over the ADDB storage engine — a hand-written
lexer / parser / planner and a result-builder Swift DSL, validated query-for-query
against SQLite.

## Overview

ADSQL adds a SQLite-grammar query engine on top of the `ADDB` storage engine: you
`prepare` a ``Statement`` once, then bind and execute it against the
transaction's schema. The supported surface covers SELECT / INSERT / UPDATE /
DELETE, joins (nested-loop, hash, and merge), subqueries, aggregates, compound
queries, upserts, and `RETURNING`, validated by a differential suite that runs every
query against SQLite.

```swift
import ADSQL

let db = try Database.open(at: "/tmp/app.adsql")
defer { db.close() }

try db.prepare("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL)").run()
try db.prepare("INSERT INTO users(name) VALUES (?)").run(.text("Ada"))

let rows = try db.prepare("SELECT id, name FROM users ORDER BY id").all()
for row in rows {
    print(row["id"], row["name"])   // .integer(1) .text("Ada")
}
```

The same query is also expressible through the type-safe **result-builder DSL**,
which lowers to the same bound plan:

```swift
let rows = try Query {
    Select(Column("id"), Column("name"))
    From("users")
    Where(Column("name") == "Ada")
    OrderBy("id")
}.all(on: db)
```

See <doc:QueryDSL> for the full builder surface (reads, writes, aggregates,
validation, and the `@Table` / `#SQL` macros), and <doc:ExecutionStrategies> for
how a statement is planned and evaluated.

The engine itself — storage, MVCC, transactions, schema definition, durability — is
documented in the `ADDB` product (`import ADDB`); `import ADSQL` re-exports it, so a
single import gives you both the engine and the SQL layer. Full-text search and JSON
are opt-in supersets: `import ADSQLFullTextSearch` and `import ADSQLJSON`.

## Topics

### Guides

- <doc:QueryDSL>
- <doc:ExecutionStrategies>

### Preparing and running SQL

- ``Statement``
- ``SQLRow``
- ``RunResult``

### The Query DSL

- ``Query``
- ``Select``
- ``From``
- ``Join``
- ``LeftJoin``
- ``Where``
- ``GroupBy``
- ``Having``
- ``OrderBy``
- ``Limit``
- ``Offset``
- ``Distinct``

### Writing rows

- ``Insert``
- ``Update``
- ``Delete``

### DSL expressions

- ``Column(_:)``
- ``Column(_:_:)``
- ``Count()``
- ``Count(_:)``
- ``Sum(_:)``
- ``Predicate``
- ``SQLColumn``
- ``SQLProjection``

### Typed rows and compile-time checks

- ``TableRow``
- ``Table(_:)``
- ``SQL(_:)``
- ``SQLBuildError``

### Version

- ``ADSQLInfo``
