# ``ADDBCore``

The storage engine: a pure-Swift, crash-safe embedded store for Swift 6 — a
copy-on-write B+tree with single-writer / wait-free-reader MVCC, with no runtime
dependency beyond the standard library.

## Overview

ADDBCore is the engine implementation. Consume it through the **`ADDB`** product,
which re-exports this module (`import ADDB`); the examples below use that import.
The `ADSQL` module layers a SQLite-grammar query engine and a Swift DSL on top, and
`ADSQLFullTextSearch` / `ADSQLJSON` add opt-in full-text-search and JSON surfaces.

The engine stores data in a single file as a **copy-on-write B+tree over an `mmap`'d page
heap** (16 KiB pages, XXH64-checksummed). Concurrency is **single-writer / wait-free
reader MVCC**: readers observe an immutable committed generation and never block the
writer, while writes are **group-committed** for durability without per-write `fsync`
cost. The on-disk format is crash-safe by construction — a partially written
generation is never observable.

```swift
import ADDB

let db = try Database.open(at: "/tmp/app.addb")
defer { db.close() }

try db.writeSync { (txn) throws(DBError) in
    try txn.createTable(
        TableDefinition(
            "users",
            columns: [
                ColumnDefinition("id", .integer, notNull: true),
                ColumnDefinition("name", .text, notNull: true),
            ],
            primaryKey: .rowidAlias(column: "id", autoincrement: true)))
    try txn.insert(into: "users", ["name": .text("Ada")])
}

let name = try db.read { (txn) throws(DBError) in
    try txn.row(in: "users", rowid: 1)?.text("name")
}
```

A read borrows a noncopyable ``ReadTxn`` pinned to one snapshot for the closure's
scope; a write runs one exclusive ``WriteTxn`` on a dedicated writer thread and
returns once it is durably committed.

### Design highlights

- **Wait-free reads** — a reader captures the committed root when it begins and
  reads only pages reachable from it, so it never blocks the writer and sees a
  stable snapshot for its whole lifetime. See <doc:Concurrency>.
- **Crash-safe by construction** — a commit publishes a new root into one of two
  checksummed meta pages; recovery picks the newest valid meta page, with no
  journal to replay. See <doc:Durability>.
- **Relational layer** — tables, typed columns with SQLite affinity, rowid and
  `WITHOUT ROWID` primary keys, secondary and covering indexes, and foreign keys,
  all over the same page heap.
- **Strict memory safety** — the engine compiles under SE-0458
  `.strictMemorySafety()`; every `Unsafe*` / `RawSpan` page view is explicitly
  scoped and lifetime-checked.

## Topics

### Guides

- <doc:Concurrency>
- <doc:Durability>

### Opening a database

- ``Database``
- ``DatabaseOptions``
- ``DurabilityProfile``

### Transactions

- ``ReadTxn``
- ``WriteTxn``

### Defining schema

- ``TableDefinition``
- ``ColumnDefinition``
- ``ColumnType``
- ``PrimaryKey``
- ``IndexDefinition``
- ``ForeignKey``

### Values

- ``Value``

### Tuning execution

- ``ExecutionOptions``
- ``ExecutionOptions/Evaluator``

### Errors and integrity

- ``DBError``
- ``IntegrityReport``
