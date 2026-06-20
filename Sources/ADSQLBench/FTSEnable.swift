import ADDBCore
import ADSQLFullTextSearch
import ADSQLJSON
import ADSQLModel

extension Database {
    /// Bench convenience: open a database with full-text search and JSON enabled, so
    /// the `search`/FTS scenarios run `MATCH`/`searchPagesFramed` (which uses
    /// `json_each`) without each open site repeating the enable calls. (Harmless for
    /// non-FTS/JSON scenarios — registration is one-time and process-wide.)
    static func openFTS(
        at path: String, options: DatabaseOptions = DatabaseOptions()
    ) throws(DBError) -> Database {
        let db = try open(at: path, options: options)
        db.enableFullTextSearch()
        db.enableJSON()
        return db
    }
}
