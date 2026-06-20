# ADDB — engine roadmap

The roadmap for the **ADDB storage engine** — the COW B+tree over `mmap`,
single-writer / wait-free-reader MVCC with snapshot isolation, crash-safe
recovery, the relational model (tables / indexes / foreign keys), and the
full-text-search index. This is the engine *only*.

The SQL language, the result-builder DSL, the macros, and the json1 surface have
their own roadmap in the separate **[ADSQL](https://github.com/g-cqd/ADSQL)**
package ([ADSQL/ROADMAP.md](https://github.com/g-cqd/ADSQL/blob/main/ROADMAP.md)).
ADSQL consumes this engine through its `@_spi(ADDBEngine)` surface; the
apple-docs-specific search target (`ADSQLSearch`) now lives in the **apple-docs**
package.

> **Two packages, not one.** ADDB (this engine) and ADSQL (the SQL layer) were
> once a single package; they are now split. The engine's deep coverage — the
> SQLite-differential suite — lives in ADSQL, which reaches engine internals
> across the package boundary via `@_spi(ADDBEngine)` plus opt-in
> `-enable-testing` (`ADDB_TESTING=1`). The engine's own characterization tests
> (`ADDBCoreTests`) keep it independently verifiable.

- Toolchain: Swift 6.x tools, module-wide `.strictMemorySafety()` (SE-0458) +
  experimental Lifetimes. macOS 15 floor (device platforms at the 2025
  generation), Linux x64 + arm64. arm64 + x86_64 (16 KiB logical pages).
- Dependency: only **ADFoundation** (`ADFCore`, `ADFIO`). No SQL, no JSON, no
  swift-syntax in the shipped graph.

**Products:** `ADDBCore` (engine) · `ADDB` (public engine façade,
`@_exported import ADDBCore`).

---

## 1. Architecture & design

### Storage kernel
- **COW B+tree over `mmap`** — 16 KiB pages, **XXH64** per-page checksums,
  overflow-page chains for large values, a page allocator + free-list that
  reclaims pages once no reader can still see them.
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
  checksum-valid meta page* (meta ping-pong + one barrier). No WAL replay.
- **Durability profiles:** `.barrier` (`F_BARRIERFSYNC`, default), `.full`
  (`F_FULLFSYNC`), `.none` (bench). O(1) atomic snapshots via APFS `clonefile(2)`
  (portable copy fallback elsewhere).

### Relational model
- Strict typed `Value` / columns; order-preserving `KeyCodec`; `RecordCodec`; a
  catalog with transactional DDL; DML with conflict policies + secondary-index
  maintenance; foreign keys (`ON DELETE CASCADE` / `RESTRICT`); deep integrity
  (index ⇄ row bijection) via `verifyIntegrity`.

### Full-text-search index
- The on-disk FTS index: postings codec with frame-of-reference bit-packing, one
  block per key (O(n) incremental build); ranked top-k via **block-max WAND**; a
  transaction-scoped postings memtable coalesces a transaction's documents before
  flush. (The `MATCH` / `bm25` / `bm25f` *query surface* lives in ADSQL.)

### Safety model
- **Module-wide strict memory safety** (SE-0458): ~620 unsafe constructs each
  explicitly `unsafe` or encapsulated by a `@safe` type, so any *new* unsafe use
  is compiler-flagged.
- `~Escapable` / `~Copyable` + `RawSpan` lifetime dependencies bind page views to
  their snapshot (`Cursor`, `ReadTxn` / `WriteTxn`, `RowView`, `ValueRef`) — they
  cannot outlive it.
- **Typed throws** (`throws(DBError)`); `Synchronization` `Mutex` / `Atomic` for
  in-process state; thread-safe libc (`strerror_r`).

### Public API & access model
- Curated `public` façade (re-exported by the `ADDB` product): `Database`,
  `ReadTxn` / `WriteTxn`, `Statement`, `SQLParameters`,
  `SQLRow` / `Row` / `SQLColumnHeader` / `RunResult`,
  `Value` / `ColumnType` / `Collation`, `DBError`, the `Definitions`
  (table / column / index), `DatabaseOptions` / `ExecutionOptions` /
  `DurabilityProfile`, `IntegrityReport` + `verifyIntegrity`.
- The broad engine API (B-tree, pager, cursors, codecs, catalog, txn context) is
  exposed as **`@_spi(ADDBEngine) public`** — invisible to ordinary consumers,
  reachable by the ADSQL package which imports the SPI. (Before the package
  split this surface was `package`; `package` access cannot cross the now-real
  package boundary, so it became SPI.)
- `ADDBCore` source is split into concern-scoped files.

---

## 2. Status

| Milestone | Status | Scope |
|---|---|---|
| **M0–M2 — Storage kernel** | ✅ done | COW B+tree over mmap; MVCC; free-list; commit protocol + crash-injection recovery; cross-process readers + writer lock; group commit. |
| **M3 — Relational layer** | ✅ done | Strict typed `Value` / columns; order-preserving `KeyCodec`; `RecordCodec`; catalog + transactional DDL; DML with conflict policies + secondary-index maintenance; FK `ON DELETE CASCADE` / `RESTRICT`; deep integrity (index ⇄ row bijection). |
| **Scan / storage perf** | ✅ done | Zero-copy row decode, ordered rowid fetch, lazy `RowView` scans, slot-bound columns at the storage boundary. Strict memory safety enabled module-wide. |
| **FTS index (M5)** | ✅ mostly done | On-disk FTS index + block-max WAND ranked top-k. The `delete / churn` re-index path is the standout open gap (re-encodes postings per doc → O(corpus)); see backlog. |
| **Package split** | ✅ done | Engine extracted to its own package; SQL/JSON/macros/search moved out. `package` storage surface re-expressed as `@_spi(ADDBEngine)` so ADSQL resolves it across the boundary; opt-in `-enable-testing` for ADSQL's white-box suite; engine characterization tests added (`ADDBCoreTests`). |
| **Linux** | ✅ builds + tests green (x64 + arm64) | The Glibc forks — `clonefile`→copy snapshot, `fdatasync` / `fsync` barriers, `posix_fallocate`, the cross-process reader table, XSI `strerror_r` — are validated at runtime. |
| **Hardening** | ⏳ future | Expanded fuzz / crash-injection coverage; operational polish. |

---

## 3. Future work (engine backlog)

### A. Storage / scan performance
- **`ANALYZE`-grade statistics at the storage layer** — per-index selectivity the
  planner (in ADSQL) can consume to pick scan-vs-seek on cost rather than a
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
- **Raw-segment postings** for build throughput (architectural).
- Finish the prefix-union / zero-copy key-read path on the index cursor.

### C. Covering / `INCLUDE`-index serving (✅ done at the storage boundary)
- The index cursor can serve rows straight off the entry value with no base-table
  descent (`RowCursor(coveringIncludes:)`). The served set is **stricter than
  `key ∪ includes`** — a non-rowid KEY column is not in the entry value, so it
  forces a descent (correctness over optimization). *Follow-on:* equality-probed
  key-column values are statically known and could be served without descent — a
  future widening, not yet done.

### D. Hardening
- Expanded fuzz / crash-injection coverage; operational polish.

### Explicitly declined (recorded so they aren't re-litigated)
`VACUUM`; `vm_copy` COW (full memcpy is faster); strong-ID typedefs
`PageNumber` / `Generation` (page arithmetic is pervasive `UInt64`, so wrappers
add `.rawValue` noise without catching bugs at that layer); a `DBError.description`
macro.

---

## 4. Engineering disciplines

- **Standing gate (every change):** `swift build` clean (0 warnings, 0 strict-MS
  over-marks) · `swift test` green · `swift test --sanitize=thread` on changed
  read / write / scan paths · crash-injection on write paths · **one concern per
  commit.**
- **Evidence-driven:** every performance claim sits behind a benchmark number
  (the vs-SQLite harness lives in ADSQL; the engine's allocation / throughput
  guards live in `Benchmarks/ADDBSuite`); diagnoses come from a profile, not a
  guess.

## Develop

```sh
swift build
swift test
swift test --sanitize=thread   # concurrency lane
```
