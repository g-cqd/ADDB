import ADSQLFullTextSearch

extension Database {
    /// Bench convenience: open a database with full-text search enabled, so the
    /// `search`/FTS scenarios run `MATCH`/`searchPagesFramed` without each open site
    /// repeating `enableFullTextSearch()`. (Harmless for non-FTS scenarios: the
    /// evaluator is read inside the snapshot lock already taken, so no extra cost.)
    static func openFTS(
        at path: String, options: DatabaseOptions = DatabaseOptions()
    ) throws(DBError) -> Database {
        let db = try open(at: path, options: options)
        db.enableFullTextSearch()
        return db
    }
}
