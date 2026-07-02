import ADDBJSON
import ADSQLModel

@_spi(ADDBEngine) import ADDBCore
@_spi(ADDBEngine) import ADDBExec

extension Database {
    /// Test convenience: open a database and enable SQL JSON (json1 functions,
    /// json_group_* aggregates, `->`/`->>`, `json_each`). `enableJSON()` is
    /// process-wide + idempotent, so this is order-safe across the test run.
    static func openJSON(
        at path: String, options: DatabaseOptions = DatabaseOptions()
    ) throws(DBError) -> Database {
        let db = try open(at: path, options: options)
        db.enableJSON()
        return db
    }
}
