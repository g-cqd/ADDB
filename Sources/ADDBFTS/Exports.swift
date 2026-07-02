// `import ADDBFTS` yields the whole SQL surface plus full-text
// search: this superset module re-exports ADSQL (which itself re-exports
// ADDBCore), so a consumer imports one module to get the engine, the SQL
// language, and MATCH/rank/bm25.
@_exported import ADSQL
