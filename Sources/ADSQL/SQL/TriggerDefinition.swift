import ADDBCore

/// A parsed `CREATE TRIGGER … AFTER <event> ON <table> FOR EACH ROW [WHEN …]
/// BEGIN <stmt>; … END`. The body is a list of INSERT/DELETE/UPDATE statements
/// evaluated with `NEW`/`OLD` bound to the affected row; `whenExpr`, when
/// present, gates firing. The original `sql` text is retained verbatim — it is
/// what the catalog stores, and the definition re-parses from it on demand
/// (mirroring SQLite's `sqlite_schema`), so the body AST never has to be
/// serialized. This is a SQL-layer type: the storage layer holds only the text.
public struct TriggerDefinition: Equatable, Sendable {
    public var name: String
    public var table: String
    public var event: TriggerEvent
    public var whenExpr: SQLExpr?
    public var body: [SQLStatementAST]
    public var sql: String

    public init(
        name: String, table: String, event: TriggerEvent, whenExpr: SQLExpr? = nil,
        body: [SQLStatementAST], sql: String
    ) {
        self.name = name
        self.table = table
        self.event = event
        self.whenExpr = whenExpr
        self.body = body
        self.sql = sql
    }
}
