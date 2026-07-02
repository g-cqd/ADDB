# ADDB

A from-scratch, pure-Swift **embedded storage engine** for Apple platforms (and
Linux). ADDB is the storage kernel only — a copy-on-write B+tree over `mmap`,
single-writer / wait-free-reader MVCC with snapshot isolation, crash-safe by
construction, plus the relational model (tables / indexes / foreign keys) and a
full-text-search index on the same on-disk format.

There is **no SQL and no JSON here**. The SQLite-grammar query layer, the
result-builder DSL, the `@Table` / `#SQL` macros, and the json1 surface live in
the separate **[ADSQL](https://github.com/g-cqd/ADSQL)** package, which consumes
this engine through its `@_spi(ADDBEngine)` surface. JSON is owned by
**[ADJSON](https://github.com/g-cqd/ADJSON)**.

- Platform: macOS 15 floor; device platforms (iOS / tvOS / watchOS / visionOS)
  at the 2025 generation; Linux x64 + arm64. arm64 + x86_64.
- Toolchain: Swift 6.x — `.v6` language mode, complete strict concurrency,
  SE-0458 strict memory safety, experimental lifetime dependence.
- Dependency: **only [ADFoundation](https://github.com/g-cqd/ADFoundation)** —
  its `ADFCore` byte/number kernel and `ADFIO` POSIX storage. No swift-syntax,
  no JSON, no SQL in the shipped graph.
- Durability profiles: `.barrier` (`F_BARRIERFSYNC`, default), `.full`
  (`F_FULLFSYNC`), `.none` (bench).

## Products

ADDB ships two library products — both pure engine, no language layer:

- **`ADDB`** — a thin public façade that re-exports the engine's curated
  `public` API (`@_exported import ADDBCore`). Use this if you want the database
  engine without SQL.
- **`ADDBCore`** — the engine module itself. Its `@_spi(ADDBEngine) public`
  surface is the broad, low-level API that a query layer (ADSQL) drives; its
  plain `public` surface is the curated façade API. General consumers should
  prefer the `ADDB` façade.

> **Why the SPI seam?** ADSQL used to live in the same package as the engine and
> reached engine internals with package-wide `@testable`/`package` access. ADDB
> and ADSQL are now **two separate packages**, and `package` access cannot cross
> a package boundary — so the engine deliberately exposes the surface ADSQL needs
> as `@_spi(ADDBEngine)`, and offers opt-in `-enable-testing` (`ADDB_TESTING=1`)
> so ADSQL's white-box tests can `@testable import ADDBCore` across the boundary.

## Architecture

### Storage kernel
- **COW B+tree over `mmap`** — 16 KiB logical pages, **XXH64** per-page
  checksums, overflow-page chains for large values, a page allocator + free-list
  that reclaims pages once no reader can still see them.
- Committed pages are **immutable**; a write transaction copies-on-write the
  pages it touches.

### Durability & concurrency
- **Single-writer / wait-free-reader MVCC** with snapshot isolation. Readers run
  lock-free against an immutable committed snapshot; one writer at a time mutates
  via a dedicated writer thread. A cross-process reader table + writer lock
  coordinate multiple processes.
- **Group commit** batches concurrent write requests; per-request undo lets one
  request roll back without aborting the batch.
- **Crash-safe by construction** — recovery is simply *picking the newest
  checksum-valid meta page* (meta ping-pong + one barrier). No WAL, no replay.
- O(1) atomic snapshots via APFS `clonefile(2)` (with a portable copy fallback).

### Relational model
- Strict typed `Value` / columns; order-preserving `KeyCodec`; `RecordCodec`;
  a catalog with transactional DDL; DML with conflict policies + secondary-index
  maintenance; foreign keys (`ON DELETE CASCADE` / `RESTRICT`); deep integrity
  checks (index ⇄ row bijection) via `verifyIntegrity`.

### Full-text-search index
- The on-disk FTS index (postings codec with frame-of-reference bit-packing, one
  block per key, O(n) incremental build) and ranked top-k via **block-max WAND**.
  The query-language surface for it (`CREATE VIRTUAL TABLE … USING fts5`, the
  `MATCH` operator, `bm25` / `bm25f`) lives in ADSQL's `ADDBFTS`.

### Safety model
- **Module-wide strict memory safety** (SE-0458): every unsafe construct is
  explicitly `unsafe` or encapsulated by a `@safe` type, so any *new* unsafe use
  is compiler-flagged.
- `~Escapable` / `~Copyable` + `RawSpan` lifetime dependencies bind page views to
  their snapshot (`Cursor`, `ReadTxn` / `WriteTxn`, `RowView`, `ValueRef`) — they
  cannot outlive it.
- **Typed throws** (`throws(DBError)`); `Synchronization` `Mutex` / `Atomic` for
  in-process state.

## Layout

- `Sources/ADDBCore` — the engine: VFS, pager, COW B+tree, MVCC transactions,
  free-list, commit protocol, recovery, integrity, the relational layer
  (tables / indexes / foreign keys), and the FTS index.
- `Sources/ADDB` — the public engine façade (`@_exported import ADDBCore`).
- `Tests/ADDBCoreTests` — engine characterization tests that pin the externally
  observable behavior of the storage / relational engine, so the package is
  verifiable on its own. The deep SQL-over-engine differential coverage lives in
  the sibling **ADSQL** package's integration suite.

## Benchmarks

The vs-SQLite benchmark harness lives in the **ADSQL** package (`ADSQLBench`,
which exercises this engine through the SQL layer). The engine's own
allocation / throughput guards (`Benchmarks/ADDBSuite`, ordo-one) run via:

```sh
ADDB_DEV=1 swift package benchmark
```

## Develop

```sh
swift build
swift test
swift test --sanitize=thread   # concurrency lane
```

See [`ROADMAP.md`](ROADMAP.md) for the engine roadmap and milestone status.
