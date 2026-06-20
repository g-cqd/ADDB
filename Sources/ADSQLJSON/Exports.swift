// `import ADSQLJSON` yields the whole SQL surface plus JSON: this superset module
// re-exports ADSQL (which re-exports ADDBCore), so a consumer imports one module
// to get the engine, the SQL language, and the json1 functions/operators after
// calling `enableJSON()`.
@_exported import ADSQL
