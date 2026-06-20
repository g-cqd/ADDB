/// ADDB — the embedded database engine: a copy-on-write B+tree over `mmap` with
/// single-writer / wait-free-reader MVCC, a strict relational model, and a
/// full-text-search index. This product is the curated public face of the
/// engine; it re-exports ``ADDBCore``. The SQL language is the separate `ADSQL`
/// module (which layers on the same engine).
///
/// **The façade boundary.** `import ADDB` exposes the **value-type API** — `Database`,
/// `Value`, the `Definitions` (tables / indexes / foreign keys / triggers), `Row`,
/// `IntegrityReport`. The engine-driver surface (the pager / B-tree / codec internals, plus
/// `MMap`, `StorageChannel`, `SchemaCache`, `RowView`, …) is gated behind `@_spi(ADDBEngine)`
/// and is reachable only with an explicit `@_spi(ADDBEngine) import ADDBCore` — the SQL layer
/// opts in; a value-type consumer never sees it. (Residual: the `Overflow` paging surface is
/// still bare-`public`; demoting it requires a coordinated demotion of `Overflow.write`/`read`
/// and is deferred.)
@_exported import ADDBCore
// Post-inversion the SQL executor (prepare/Statement/SQLRow + the @Table/Query DSL) lives in
// ADDBExec; the façade re-exports it so `import ADDB` is the single entry point for engine + SQL.
@_exported import ADDBExec
