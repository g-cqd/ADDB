# ADDB

A from-scratch, pure-Swift **embedded database** for Apple platforms (and
Linux). ADDB is the storage engine — a copy-on-write B+tree over `mmap`,
single-writer / wait-free-reader MVCC with snapshot isolation, crash-safe by
construction, the relational model (tables / indexes / foreign keys /
triggers), and an on-disk full-text-search index — **plus the SQL execution
layer that runs on it**: the executor / evaluator (`ADDBExec`), the `@Table` /
`#SQL` macros, an async façade, the opt-in FTS / JSON / migration / import
supersets, and the `adsql` CLI.

The SQL **frontend** — lexer → parser → binder → heuristic planner, plus the
shared `ADSQLModel` value/schema model — lives in the separate,
dependency-free **[ADSQL](https://github.com/g-cqd/ADSQL)** package, which
this package depends on. Execution lives here, beside the concrete engine, so
`Value` / `Cursor` stay monomorphic and fast; ADSQL stays a pure, portable
language layer. SQLite-dialect JSON is owned by
**[ADJSON](https://github.com/g-cqd/ADJSON)**.

- Platform: macOS 15 floor; device platforms (iOS / tvOS / watchOS / visionOS)
  at the v26 generation; Linux x64 + arm64. arm64 + x86_64 (16 KiB logical
  pages).
- Toolchain: Swift 6.x — `.v6` language mode, complete strict concurrency; the
  engine and executor build with SE-0458 strict memory safety and experimental
  lifetime dependence.
- Dependencies: **[ADSQL](https://github.com/g-cqd/ADSQL)** (`ADSQLModel` +
  `ADSQL`), **[ADFoundation](https://github.com/g-cqd/ADFoundation)**
  (`ADFCore` byte/number kernel, `ADFIO` POSIX storage, `ADFUnicode`;
  `ADConcurrency` for the async façade),
  **[ADJSON](https://github.com/g-cqd/ADJSON)** (`ADJSONCore`, linked by
  `ADDBJSON` only), `swift-collections` (`OrderedCollections`, the GROUP BY
  accumulation table), and `swift-syntax` — **macro-plugin build time only**;
  no shipped non-macro product links it.
- Durability profiles: `.barrier` (`F_BARRIERFSYNC`, default), `.full`
  (`F_FULLFSYNC`), `.none` (bench).

## Products

| Product | What it is |
| --- | --- |
| **`ADDB`** | The curated façade — engine + SQL execution from one import: `Database`, transactions, `prepare` / `Statement` / `SQLRow`, `Value`, the `Definitions`, `DBError` (re-exports `ADDBCore` + `ADDBExec` + `ADSQLModel`). |
| **`ADDBCore`** | The storage engine itself: curated `public` surface, plus the broad engine-driver API (pager / B-tree / cursors / codecs / catalog) gated behind `@_spi(ADDBEngine)`. |
| **`ADDBExec`** | The SQL executor / evaluator: runs ADSQL's bound plans over the engine — single-table & joined SELECT, DML with conflict policies + `RETURNING`, grouping / aggregates, triggers, the scalar & aggregate function registries, the typed `TableRow` row model, statement + bound-plan caches. |
| **`ADDBAsync`** | The async façade: concurrent async reads / serialized async writes over the engine's blocking `read` / `writeSync`, offloaded via `ADConcurrency.BlockingOffloadPool` so the cooperative pool never blocks. |
| **`ADDBMacros`** | The `@Table` / `#SQL` macro sugar (declarations; the `ADSQLMacros` compiler plugin implements them). Isolated so no other product pulls swift-syntax. |
| **`ADDBFTS`** | The FTS query surface — `CREATE VIRTUAL TABLE … USING fts5`, `MATCH`, `bm25` / `bm25f` per-column weights, block-max WAND ranked top-k — installed via `Database.enableFullTextSearch()`. The on-disk index itself is engine-maintained on every write. |
| **`ADDBJSON`** | The SQLite `json1` surface (`json_*` functions, `->` / `->>`, `json_group_*` aggregates), ADJSON-backed, installed via `Database.enableJSON()`. The core stays ADJSON-free. |
| **`ADDBMigrate`** | Integer-versioned, transactional schema migrations (`Migration` / `Migrator` over a `schema_version` cursor), including the recreate-and-copy path for column-shape changes. |
| **`ADDBImport`** | The SQLite-file importer: reads a `.db` via system SQLite (`CSQLite`) and writes an ADDB database — loose→strict `Value` coercion, index/PK/UNIQUE port, manifest-driven FTS5 reconstruction, build-time denormalization; idempotent and deterministic. |
| **`adsql`** | The CLI executable (`ADSQLTool`): `create` / `put` / `get` / `delete` / `scan` / `stats` / `check` / `tables` / `schema` / `import` / `snapshot`. |

## Architecture

### Storage kernel
- **COW B+tree over `mmap`** — 16 KiB logical pages, **XXH64** per-page
  checksums, overflow-page chains for large values, a page allocator +
  free-list that reclaims pages once no reader can still see them.
- Committed pages are **immutable**; a write transaction copies-on-write the
  pages it touches.

### Durability & concurrency
- **Single-writer / wait-free-reader MVCC** with snapshot isolation. Readers
  run lock-free against an immutable committed snapshot; one writer at a time
  mutates via a dedicated writer thread. A cross-process reader table + writer
  lock coordinate multiple processes.
- **Group commit** batches concurrent write requests; per-request undo lets
  one request roll back without aborting the batch.
- **Crash-safe by construction** — recovery is simply *picking the newest
  checksum-valid meta page* (meta ping-pong + one barrier). No WAL, no replay.
- O(1) atomic snapshots via APFS `clonefile(2)` (portable copy fallback on
  Linux).

### Relational model
- Strict typed `Value` / columns; order-preserving `KeyCodec`; `RecordCodec`;
  a catalog with transactional DDL; DML with conflict policies +
  secondary-index maintenance; foreign keys (`ON DELETE CASCADE` /
  `RESTRICT`); row triggers; deep integrity checks (index ⇄ row bijection) via
  `verifyIntegrity`.

### SQL execution
- ADSQL parses, binds, and plans the statement; **`ADDBExec` executes the
  bound plan** against the concrete engine: row sources (scan / rowid / index
  / FTS, including covering-index serving with no base-table descent), join
  execution, grouping / aggregation, `CREATE TRIGGER` firing inside the same
  write transaction, and per-`Statement` bound-plan caching.
  `Statement.forEach` streams rows one at a time (the `sqlite3_step` model).
- The supersets register their surfaces at runtime — `enableFullTextSearch()`
  installs `MATCH` / `bm25` evaluation, `enableJSON()` the json1 functions —
  so the core link graph stays lean.
- The executor's behavior is pinned by a SQLite-differential integration
  suite (`Tests/ADSQLTests` + the FTS / import / migrate suites).

### Full-text search
- The engine owns the on-disk FTS index: postings codec with
  frame-of-reference bit-packing, one block per key, O(n) incremental build, a
  transaction-scoped postings memtable. `ADDBFTS` owns the query surface:
  `MATCH`, `bm25` / `bm25f`, ranked top-k via **block-max WAND** — proven
  byte-parity with SQLite FTS5 (scores *and* ranked order) through the
  importer.

### Safety model
- **Module-wide strict memory safety** (SE-0458) in the kernel + executor:
  every unsafe construct is explicitly `unsafe` or encapsulated by a `@safe`
  type, so any *new* unsafe use is compiler-flagged.
- `~Escapable` / `~Copyable` + `RawSpan` lifetime dependencies bind page views
  to their snapshot (`Cursor`, `ReadTxn` / `WriteTxn`, `RowView`, `ValueRef`)
  — they cannot outlive it.
- **Typed throws** (`throws(DBError)`); `Synchronization` `Mutex` / `Atomic`
  for in-process state.

## Layout

- `Sources/ADDBCore` — the engine: VFS, pager, COW B+tree, MVCC transactions,
  free-list, commit protocol, recovery, integrity, the relational layer, and
  the FTS index.
- `Sources/ADDBExec` — the SQL executor / evaluator over the engine.
- `Sources/ADDBFTS` / `ADDBJSON` / `ADDBMigrate` / `ADDBImport` — the opt-in
  supersets.
- `Sources/ADDB` — the public façade; `Sources/ADDBAsync` — the async façade.
- `Sources/ADDBMacros` + `Sources/ADSQLMacros` — the `@Table` / `#SQL` macro
  layer (declarations + compiler plugin).
- `Sources/ADSQLTool` — the `adsql` CLI; `Sources/ADSQLBench` — the vs-SQLite
  benchmark harness.
- `Tests/` — dev-gated (`ADDB_DEV=1`): `ADSQLTests` (the SQL-over-engine
  integration + SQLite-differential suite), `ADDBCoreTests` (engine
  characterization), `ADDBFTSTests`, `ADDBImportTests`, `ADDBMigrateTests`,
  `ADDBMacrosTests`, `ADDBAsyncTests`, `ADDBSmokeTests`, and the shared
  `ADDBTestSupport` fixture.

## Benchmarks

- `ADSQLBench` — the vs-SQLite (+ FTS5) differential benchmark harness:
  `swift run -c release ADSQLBench`.
- `Benchmarks/ADDBSuite` — the ordo-one allocation / throughput guards
  (storage codec path + SQL / FTS hot paths): `ADDB_DEV=1 swift package
  benchmark`.

## Develop

```sh
swift build                          # library graph only
ADDB_DEV=1 swift test                # full suite (tests are dev-gated)
ADDB_DEV=1 swift test --sanitize=thread   # concurrency lane
```

Local sibling checkouts resolve via `ADSQL_PATH` / `ADFOUNDATION_PATH` /
`ADJSON_PATH` / `ADBUILDTOOLS_PATH`; unset, siblings resolve from GitHub
`main`.

See [`ROADMAP.md`](ROADMAP.md) for status and the backlog, and `docs/rfcs/`
for the active design programs (apple-docs integration, table-valued
functions).
