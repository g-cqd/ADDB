@_spi(ADDBEngine) import ADDBCore
import ADSQL
public import ADSQLModel
import Synchronization

/// A multi-statement write transaction: every statement runs against one
/// shared `WriteTxn`, so a batch of writes commits once (one durability
/// point) instead of per statement. The handle is only valid inside the
/// `transaction` closure — using it afterward is undefined.
public final class SQLTransaction {
    private let database: Database
    private let ctx: TxnContext

    init(database: Database, ctx: TxnContext) {
        self.database = database
        self.ctx = ctx
    }

    @discardableResult
    public func run(_ sql: String, _ params: Value...) throws(DBError) -> RunResult {
        try run(sql, SQLParameters(positional: params))
    }
    @discardableResult
    public func run(_ sql: String, _ named: [String: Value]) throws(DBError) -> RunResult {
        try run(sql, SQLParameters(named: named))
    }
    @discardableResult
    public func run(_ sql: String, _ params: SQLParameters) throws(DBError) -> RunResult {
        let parsed = try database.parsedStatement(sql)
        switch parsed.ast {
            case .select, .begin, .commit, .rollback:
                throw DBError.sqlUnsupported(
                    "only INSERT/UPDATE/DELETE/DDL run inside a transaction block")
            default:
                let txn = WriteTxn(ctx: ctx)
                return try Writer.execute(parsed.ast, txn: txn, params: params).result
        }
    }
}

extension Database {
    /// Parses (reusing the parse cache) without constructing a `Statement`.
    func parsedStatement(_ sql: String) throws(DBError) -> ParsedStatement {
        if let cached = withStatementCache({ $0.get(sql) }) { return cached }
        let ast = try SQLParser.parseOne(sql)
        let parsed = ParsedStatement(ast: ast, isReadOnly: ast.isReadOnly)
        withStatementCache { $0.insert(sql, parsed) }
        return parsed
    }

    /// Runs `body` against one exclusive write transaction; its statements
    /// commit together when `body` returns (or roll back if it throws).
    @discardableResult
    public func transaction<R>(
        _ body: (SQLTransaction) throws(DBError) -> R
    ) throws(DBError) -> R {
        installTriggerEngine(SQLTriggerEngine.shared)
        return try writeSync { (txn) throws(DBError) in
            try body(SQLTransaction(database: self, ctx: txn.ctx))
        }
    }

    /// Runs `body` in one write transaction with `table`'s triggers SUSPENDED: they are dropped, `body`
    /// runs (its writes to `table` fire none of them), then they are recreated — all inside the single
    /// transaction, so any throw rolls the whole unit back and the triggers are never actually lost.
    ///
    /// The lever for a bulk write of columns a trigger doesn't read: an `AFTER UPDATE` FTS-sync trigger
    /// re-encodes a whole posting list per row (quadratic over N rows); suspending it makes the write
    /// linear. The CALLER guarantees the writes preserve the triggers' invariant (e.g. leave the
    /// FTS-source columns untouched, so the FTS index stays correct) — this helper re-syncs nothing.
    @discardableResult
    public func suspendingTriggers<R>(
        on table: String, _ body: (SQLTransaction) throws(DBError) -> R
    ) throws(DBError) -> R {
        try transaction { (txn) throws(DBError) in
            let saved = try txn.triggerDefinitions(on: table)
            for trigger in saved { try txn.run("DROP TRIGGER IF EXISTS \(trigger.name)") }
            let result = try body(txn)
            for trigger in saved { try txn.run(trigger.ddl) }
            return result
        }
    }
}

extension SQLTransaction {
    /// The `(name, CREATE-TRIGGER text)` of every trigger defined on `table`, name-sorted — the DDL needed
    /// to drop and later recreate them (see ``Database/suspendingTriggers(on:_:)``). Reads this
    /// transaction's own schema state, so it reflects triggers created/dropped earlier in the same txn.
    func triggerDefinitions(on table: String) throws(DBError) -> [(name: String, ddl: String)] {
        let state = try Relation.ensureState(ctx)
        var out: [(name: String, ddl: String)] = []
        for name in state.triggerTexts.keys.sorted() {
            guard let ddl = state.triggerTexts[name] else { continue }
            if try SQLTriggerEngine.parse(ddl, expectedName: name).table == table {
                out.append((name: name, ddl: ddl))
            }
        }
        return out
    }
}
