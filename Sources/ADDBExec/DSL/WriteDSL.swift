@_spi(ADDBEngine) public import ADDBCore
import ADSQL
public import ADSQLModel

/// `INSERT INTO <table>(columns) VALUES …`, lowering to the engine's `SQLInsert`
/// AST so binding, conflict handling, index maintenance, and FK actions are the
/// proven write path — the builder is a typed front door, not a second writer.
///
/// ```swift
/// try Insert(into: "users", columns: ["id", "name"], values: [1, "Ada"]).run(on: db)
/// try Insert(into: "users", columns: ["id", "name"], rows: [[2, "Bo"], [3, "Cy"]])
///     .orIgnore().run(on: db)
/// ```
public struct Insert: Sendable {
    var statement: SQLInsert

    /// A single row.
    public init(into table: String, columns: [String], values: [any SQLExpressionConvertible]) {
        self.init(into: table, columns: columns, rows: [values])
    }

    /// Several rows in one statement.
    public init(into table: String, columns: [String], rows: [[any SQLExpressionConvertible]]) {
        statement = SQLInsert(
            table: table, columns: columns,
            source: .values(rows.map { $0.map(\.sqlExpression) }), offset: 0)
    }

    /// `INSERT OR REPLACE` — replace a conflicting row.
    public func orReplace() -> Insert { with { $0.conflict = .replace } }
    /// `INSERT OR IGNORE` — skip a conflicting row.
    public func orIgnore() -> Insert { with { $0.conflict = .ignore } }

    private func with(_ mutate: (inout SQLInsert) -> Void) -> Insert {
        var copy = self
        mutate(&copy.statement)
        return copy
    }

    @discardableResult
    public func run(on db: Database) throws(DBError) -> RunResult {
        try db.writeSync { (txn) throws(DBError) in
            try Writer.execute(.insert(statement), txn: txn, params: SQLParameters()).result
        }
    }
}

/// `UPDATE <table> SET … [WHERE …]`, lowering to the engine's `SQLUpdate` AST.
///
/// ```swift
/// try Update("users").set("name", to: "Ada").where { $0.id == 1 }.run(on: db)
/// ```
public struct Update: Sendable {
    var statement: SQLUpdate

    public init(_ table: String) {
        statement = SQLUpdate(table: table, sets: [], whereExpr: nil, offset: 0)
    }

    /// Appends `column = value` to the SET list.
    public func set(_ column: String, to value: some SQLExpressionConvertible) -> Update {
        var copy = self
        copy.statement.sets.append(SQLAssignment(column: column, value: value.sqlExpression, offset: 0))
        return copy
    }

    /// Sets the WHERE predicate (replaces any prior one).
    public func `where`(_ predicate: Predicate) -> Update {
        var copy = self
        copy.statement.whereExpr = predicate.expression
        return copy
    }
    /// `WHERE` via a column proxy: `.where { $0.id == 1 }`.
    public func `where`(_ build: (ColumnProxy) -> Predicate) -> Update {
        self.where(build(ColumnProxy()))
    }

    @discardableResult
    public func run(on db: Database) throws(DBError) -> RunResult {
        try db.writeSync { (txn) throws(DBError) in
            try Writer.execute(.update(statement), txn: txn, params: SQLParameters()).result
        }
    }
}

/// `DELETE FROM <table> [WHERE …]`, lowering to the engine's `SQLDelete` AST.
/// A `Delete` with no `where` deletes every row.
///
/// ```swift
/// try Delete(from: "users").where { $0.id == 1 }.run(on: db)
/// ```
public struct Delete: Sendable {
    var statement: SQLDelete

    public init(from table: String) {
        statement = SQLDelete(table: table, whereExpr: nil, offset: 0)
    }

    public func `where`(_ predicate: Predicate) -> Delete {
        var copy = self
        copy.statement.whereExpr = predicate.expression
        return copy
    }
    public func `where`(_ build: (ColumnProxy) -> Predicate) -> Delete {
        self.where(build(ColumnProxy()))
    }

    @discardableResult
    public func run(on db: Database) throws(DBError) -> RunResult {
        try db.writeSync { (txn) throws(DBError) in
            try Writer.execute(.delete(statement), txn: txn, params: SQLParameters()).result
        }
    }
}
