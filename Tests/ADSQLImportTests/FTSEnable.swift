import ADSQLFullTextSearch

extension Database {
    /// Test convenience: open a database and enable SQL full-text search, so the
    /// import/search suites exercise `MATCH`/`searchPagesFramed` without repeating
    /// the `enableFullTextSearch()` call at every open site.
    static func openFTS(
        at path: String, options: DatabaseOptions = DatabaseOptions()
    ) throws(DBError) -> Database {
        let db = try open(at: path, options: options)
        db.enableFullTextSearch()
        return db
    }
}
