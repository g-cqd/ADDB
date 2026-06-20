import ADSQLFullTextSearch
import ADSQLJSON
import ADSQLModel

@_spi(ADDBEngine) @testable import ADDBExec

extension Database {
    /// Test convenience: open a database and enable both SQL full-text search and
    /// JSON, so the import/search suites exercise `MATCH`/`searchPagesFramed` and the
    /// json_* / json_each query surface without repeating the enable calls at every
    /// open site.
    static func openFTS(
        at path: String, options: DatabaseOptions = DatabaseOptions()
    ) throws(DBError) -> Database {
        let db = try open(at: path, options: options)
        db.enableFullTextSearch()
        db.enableJSON()
        return db
    }
}
