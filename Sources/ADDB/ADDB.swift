/// ADDB — the embedded database engine: a copy-on-write B+tree over `mmap` with
/// single-writer / wait-free-reader MVCC, a strict relational model, and a
/// full-text-search index. This product is the curated public face of the
/// engine; it re-exports ``ADDBCore``. The SQL language is the separate `ADSQL`
/// module (which layers on the same engine).
@_exported import ADDBCore
