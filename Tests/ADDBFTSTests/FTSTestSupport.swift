import ADDBFTS
import ADSQLModel

@_spi(ADDBEngine) @testable import ADDBCore
@_spi(ADDBEngine) @testable import ADDBExec

extension Database {
    /// Test convenience: open a database and enable SQL full-text search in one
    /// step, so these query-language suites get `MATCH`/`rank`/`bm25` without
    /// repeating the `enableFullTextSearch()` call at every open site.
    static func openFTS(
        at path: String, options: DatabaseOptions = DatabaseOptions()
    ) throws(DBError) -> Database {
        let db = try open(at: path, options: options)
        db.enableFullTextSearch()
        return db
    }
}
