# ADDB — roadmap

The roadmap for **ADDB, the embedded database: storage engine + SQL
execution**. This package owns the COW B+tree over `mmap`,
single-writer / wait-free-reader MVCC with snapshot isolation, crash-safe
recovery, the relational model (tables / indexes / foreign keys / triggers),
the on-disk full-text-search index, **and the layers that run on the engine**:
the SQL executor / evaluator (`ADDBExec`), the `@Table` / `#SQL` macros, the
async façade (`ADDBAsync`), the opt-in supersets (`ADDBFTS` / `ADDBJSON` /
`ADDBMigrate` / `ADDBImport`), and the `adsql` CLI.

The SQL **frontend** — lexer → parser → binder → heuristic planner, plus the
shared `ADSQLModel` value/schema model — has its own roadmap in the separate,
dependency-free **[ADSQL](https://github.com/g-cqd/ADSQL)** package
([ADSQL/ROADMAP.md](https://github.com/g-cqd/ADSQL/blob/main/ROADMAP.md)).
The boundary: ADSQL produces the bound plan; `ADDBExec` executes it over the
concrete engine. The apple-docs-specific search target (`ADSQLSearch`) lives
in the **apple-docs** package.

> **The inversion, recorded.** ADDB and ADSQL were once one package, then split
> engine-out (ADSQL consumed the engine via `@_spi(ADDBEngine)`). That split
> has since been **inverted**: the executor, the supersets, the macros, and the
> SQL test suites re-homed *here*, and ADSQL slimmed to the engine-free
> frontend that ADDB now depends on. Execution beside the engine keeps
> `Value` / `Cursor` monomorphic (no cross-package existentials on the hot
> path); the frontend stays pure and portable. The former `ADSQL*`-prefixed
> superset products shipped from this package are renamed `ADDB*` — the ADSQL
> prefix now unambiguously means the frontend package.

- Toolchain: Swift 6.x tools, `.v6` language mode; the kernel + executor build
  with module-wide `.strictMemorySafety()` (SE-0458) + experimental Lifetimes.
  macOS 15 floor (device platforms at the v26 generation), Linux x64 + arm64.
  arm64 + x86_64 (16 KiB logical pages).
- Dependencies: **ADSQL** (`ADSQLModel` + `ADSQL`), **ADFoundation** (`ADFCore`,
  `ADFIO`, `ADFUnicode`, `ADConcurrency`), **ADJSON** (`ADJSONCore`, ADDBJSON
  only), `swift-collections`, `swift-syntax` (macro plugin only).
- Test + benchmark targets are dev-gated behind `ADDB_DEV=1`.

**Products:** `ADDB` (façade: engine + execution) · `ADDBCore` (engine) ·
`ADDBExec` (executor) · `ADDBAsync` (async façade) · `ADDBMacros` (macro
sugar) · `ADDBFTS` / `ADDBJSON` / `ADDBMigrate` / `ADDBImport` (opt-in
supersets) · `adsql` (CLI).

---

## 1. Architecture & design

### Storage kernel
- **COW B+tree over `mmap`** — 16 KiB pages, **XXH64** per-page checksums,
  overflow-page chains for large values, a page allocator + free-list that
  reclaims pages once no reader can still see them.
- Committed pages are **immutable**; a write transaction copies-on-write the
  pages it touches.

### Durability & concurrency
- **Single-writer / wait-free-reader MVCC** with snapshot isolation. Readers
  run lock-free against an immutable committed snapshot; one writer at a time
  mutates via a dedicated writer thread. A cross-process reader table + writer
  lock coordinate multiple processes.
- **Group commit** batches concurrent write requests; per-request undo lets one
  request roll back without aborting the batch.
- **Crash-safe by construction** — recovery is simply *picking the newest
  checksum-valid meta page* (meta ping-pong + one barrier). No WAL replay.
- **Durability profiles:** `.barrier` (`F_BARRIERFSYNC`, default), `.full`
  (`F_FULLFSYNC`), `.none` (bench). O(1) atomic snapshots via APFS
  `clonefile(2)` (portable copy fallback on Linux).

### Relational model
- Strict typed `Value` / columns; order-preserving `KeyCodec`; `RecordCodec`; a
  catalog with transactional DDL; DML with conflict policies + secondary-index
  maintenance; foreign keys (`ON DELETE CASCADE` / `RESTRICT`); row triggers;
  deep integrity (index ⇄ row bijection) via `verifyIntegrity`.

### SQL execution (`ADDBExec` + supersets)
- Executes ADSQL's **bound plan** over the engine: row sources (scan / rowid /
  index / FTS, including covering-index serving with no base-table descent),
  join execution, grouping / aggregation, DML + `RETURNING`, trigger firing
  inside the same write transaction, scalar & aggregate function registries,
  per-`Statement` bound-plan caching, and `Statement.forEach` row streaming.
- Supersets install their surfaces at runtime (`enableFullTextSearch()`,
  `enableJSON()`), keeping swift-syntax and ADJSON out of the core link graph.
- Behavior is pinned by the SQLite-differential integration suite
  (`ADSQLTests` + the FTS / import / migrate suites, re-homed here in the
  inversion).

### Full-text-search index
- The on-disk FTS index: postings codec with frame-of-reference bit-packing,
  one block per key (O(n) incremental build); ranked top-k via **block-max
  WAND**; a transaction-scoped postings memtable coalesces a transaction's
  documents before flush. The `MATCH` / `bm25` / `bm25f` query surface is
  `ADDBFTS`, with bm25f score **and** ranked-order byte-parity proven against
  SQLite FTS5 through the importer.

### Safety model
- **Module-wide strict memory safety** (SE-0458): every unsafe construct
  explicitly `unsafe` or encapsulated by a `@safe` type, so any *new* unsafe
  use is compiler-flagged.
- `~Escapable` / `~Copyable` + `RawSpan` lifetime dependencies bind page views
  to their snapshot (`Cursor`, `ReadTxn` / `WriteTxn`, `RowView`, `ValueRef`) —
  they cannot outlive it.
- **Typed throws** (`throws(DBError)`); `Synchronization` `Mutex` / `Atomic`
  for in-process state; thread-safe libc (`strerror_r`).

### Public API & access model
- Curated `public` façade (the `ADDB` product): `Database`,
  `ReadTxn` / `WriteTxn`, `prepare` / `Statement` / `SQLParameters`,
  `SQLRow` / `Row` / `SQLColumnHeader` / `RunResult`,
  `Value` / `ColumnType` / `Collation`, `DBError`, the `Definitions`
  (table / column / index / trigger), `DatabaseOptions` / `ExecutionOptions` /
  `DurabilityProfile`, `IntegrityReport` + `verifyIntegrity`.
- The broad engine API (B-tree, pager, cursors, codecs, catalog, txn context)
  is **`@_spi(ADDBEngine) public`** — invisible to ordinary consumers, driven
  by the in-package execution layer (and available to white-box tooling).

---

## 2. Status

| Milestone | Status | Scope |
|---|---|---|
| **M0–M2 — Storage kernel** | ✅ done | COW B+tree over mmap; MVCC; free-list; commit protocol + crash-injection recovery; cross-process readers + writer lock; group commit. |
| **M3 — Relational layer** | ✅ done | Strict typed `Value` / columns; order-preserving `KeyCodec`; `RecordCodec`; catalog + transactional DDL; DML with conflict policies + secondary-index maintenance; FK `ON DELETE CASCADE` / `RESTRICT`; deep integrity (index ⇄ row bijection). |
| **Scan / storage perf** | ✅ done | Zero-copy row decode, ordered rowid fetch, lazy `RowView` scans, slot-bound columns at the storage boundary, covering-index serving. Strict memory safety enabled module-wide. |
| **FTS index (M5)** | ✅ mostly done | On-disk FTS index + block-max WAND ranked top-k; bm25f score + ranked-order parity vs SQLite FTS5. The `delete / churn` re-index path is the standout open gap (re-encodes postings per doc → O(corpus)); see backlog. |
| **SQL execution over the engine** | ✅ done (surface of record) | `ADDBExec` runs ADSQL's bound plans at SQLite-differential parity for the shipped surface — SELECT/joins/aggregates/DML/`RETURNING`/triggers/PRAGMA-compat — pinned by the re-homed integration suite; the apple-docs main query is byte-identical to SQLite. Deferred surface listed in §3E. |
| **The inversion (consolidation)** | ✅ done | Executor + supersets + macros + SQL test suites re-homed here; ADSQL slimmed to the engine-free frontend ADDB depends on; the `ADDBAsync` package folded in as a target; superset products renamed `ADSQL*` → `ADDB*`; test + bench targets dev-gated behind `ADDB_DEV=1`. |
| **Linux (RFC 0010 F0)** | ✅ done (advisory lane) | Glibc forks (`clonefile`→copy snapshot, `fdatasync` / `fsync` barriers, `posix_fallocate`, cross-process reader table, XSI `strerror_r`) validated at runtime: `swift build` + the full suite pass on x64 + arm64 in CI. The lane stays advisory (pinned dated nightly) until a stable ≥ 6.4 toolchain parses the manifest — then make it required. |
| **apple-docs integration (RFC 0010)** | ⏳ ACTIVE — the driving program | P0a adoption gates all met (F0 Linux, F1 importer, F2 FTS parity, F3 main-query parity); the swap premise is **confirmed on the real 4 GB corpus** (~2.2× SQLite at 8-way, 6.4× scaling, F6 denorm productionized). Remaining: the cross-repo `INT` engine swap (`ad_storage_*` shim in apple-docs), then P1 boundary collapse. |
| **Hardening** | ⏳ future | Expanded fuzz / crash-injection coverage; operational polish. |

---

## 3. Future work

### A. Storage / scan performance
- **`ANALYZE`-grade statistics at the storage layer** — per-index selectivity
  the planner (in ADSQL) can consume to pick scan-vs-seek on cost rather than a
  heuristic.
- **Ordered / batched rowid sweep + `madvise` prefetch** (bitmap-heap-scan
  style); **per-page zone maps (min / max)** to skip leaf pages on filtered
  scans.
- **Zero-copy reads on UPDATE / DELETE / `materializeRow`**; drop the residual
  write-path `Array(s.utf8)` copies (trivial).
- **Deferred (documented, unscheduled):** spillable external merge-sort;
  morsel-parallel scans (natural under multi-reader MVCC); COW write-path
  page-copy tuning.

### B. FTS index
- The **delete / churn re-index path** — the standout gap, re-encodes postings
  per doc → O(corpus).
- **Raw-segment postings** for build throughput (architectural; the FTS *build*
  is ~30× slower than SQLite's — real, but off the read path).
- Finish the prefix-union / zero-copy key-read path on the index cursor.

### C. Covering / `INCLUDE`-index serving (✅ done at the storage boundary)
- The index cursor can serve rows straight off the entry value with no
  base-table descent (`RowCursor(coveringIncludes:)`). The served set is
  **stricter than `key ∪ includes`** — a non-rowid KEY column is not in the
  entry value, so it forces a descent (correctness over optimization).
  *Follow-on:* equality-probed key-column values are statically known and could
  be served without descent — a future widening, not yet done.

### D. Hardening
- Expanded fuzz / crash-injection coverage; operational polish.

### E. Deferred SQL execution surface
- **Table-valued functions** (`json_each` / `json_tree` as real `FROM`
  sources, incl. correlated use) — designed in
  [RFC 0011](docs/rfcs/0011-table-valued-functions.md), no code yet. Today
  `json_each` exists only in the contracted
  `x IN (SELECT value FROM json_each(…))` predicate shape — which is what the
  apple-docs query needs.
- **FROM-clause subqueries / CTEs** — parsed-and-rejected; a TVF is
  structurally simpler and neither requires nor unblocks them.
- A **VDBE-style compiled eval** stays deferred: the apple-docs read path is
  the one measured workload that would justify it (per-match tree-walk eval is
  its residual single-thread gap), and the swap already wins without it.

### F. apple-docs read-engine program (RFC 0010)
- **`INT` — the `ad_storage_*` engine swap** (cross-repo, in apple-docs): the
  `@_cdecl ad_storage_search_pages` decode-shim → `ADSQLSearch.searchPagesFramed`
  over an imported corpus, landing dark behind `APPLE_DOCS_NATIVE`. The last
  P0a gate item.
- **P1 boundary collapse:** A1 compiled `FTSSearchPlan` → A2 caller-driven row
  encoder (`RawSpan` cells) → A3 one-call `searchFramed(into:)` → A4 mmap→out
  single-copy TEXT/BLOB.
- **P2 polish:** A6 per-request pinned snapshot + plan cache; A7 vectorized
  top-k projection. (A5 filters-into-scan is **refuted** by profiling — the
  SEEK + decode dominates, not scoring.)

### Explicitly declined (recorded so they aren't re-litigated)
`VACUUM`; `vm_copy` COW (full memcpy is faster); strong-ID typedefs
`PageNumber` / `Generation` (page arithmetic is pervasive `UInt64`, so wrappers
add `.rawValue` noise without catching bugs at that layer); a
`DBError.description` macro.

---

## 4. Engineering disciplines

- **Standing gate (every change):** `swift build` clean (0 warnings, 0
  strict-MS over-marks) · `ADDB_DEV=1 swift test` green ·
  `ADDB_DEV=1 swift test --sanitize=thread` on changed read / write / scan
  paths · crash-injection on write paths · **one concern per commit.**
- **Evidence-driven:** every performance claim sits behind a benchmark number
  (`ADSQLBench` vs system SQLite + FTS5; the allocation / throughput guards in
  `Benchmarks/ADDBSuite` via `ADDB_DEV=1 swift package benchmark`); diagnoses
  come from a profile, not a guess.
- **Design programs live in `docs/rfcs/`** — 0010 (apple-docs integration,
  active) and 0011 (table-valued functions, proposed). The RFC owns the
  detail; this roadmap owns the priority.

## Develop

```sh
swift build                               # library graph only
ADDB_DEV=1 swift test                     # full suite (tests are dev-gated)
ADDB_DEV=1 swift test --sanitize=thread   # concurrency lane
```
