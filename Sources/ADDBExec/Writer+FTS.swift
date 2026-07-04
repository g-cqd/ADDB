@_spi(ADDBEngine) import ADDBCore
import ADSQL
import ADSQLModel

/// FTS5 write path for `Writer`. The
/// INSERT/UPDATE/DELETE handling for FTS5 virtual tables — the `insert`/`delete`/
/// `delete-all`/`rebuild` command dispatch, docid resolution, and the column-text
/// extraction helpers. An `extension Writer`; code motion + visibility.
extension Writer {
    static func insertFTS(
        _ insert: SQLInsert, txn: borrowing WriteTxn, params: SQLParameters
    ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
        guard insert.returning.isEmpty else { throw DBError.sqlUnsupported("RETURNING on an FTS table") }
        guard insert.conflict == .abort else {
            throw DBError.sqlUnsupported("INSERT OR …/upsert on an FTS table")
        }
        guard let definition = try txn.schema().ftsTables[insert.table] else {
            throw DBError.noSuchTable(insert.table)
        }
        // The fts5 command idiom: a first column named after the table carries a
        // command ('delete' / 'delete-all') in its value rather than row content.
        if insert.columns.first == insert.table {
            return try ftsCommand(insert, txn: txn, params: params)
        }
        // Map each INSERT column to an FTS column index, or the implicit rowid slot.
        let targetNames = insert.columns.isEmpty ? definition.columns : insert.columns
        var rowidSlot: Int?
        var ftsColumnForSlot: [Int?] = []
        ftsColumnForSlot.reserveCapacity(targetNames.count)
        for (position, name) in targetNames.enumerated() {
            if name.lowercased() == "rowid" {
                rowidSlot = position
                ftsColumnForSlot.append(nil)
            } else if let column = definition.columns.firstIndex(of: name) {
                ftsColumnForSlot.append(column)
            } else {
                throw DBError.noSuchColumn(table: insert.table, column: name)
            }
        }

        let paramsEnv = writeEnv(txn: txn, params: params)
        var changes = 0
        var lastRowid: Int64 = 0

        func indexRow(_ values: [Value]) throws(DBError) {
            guard values.count == targetNames.count else {
                throw DBError.sqlBind("\(values.count) values for \(targetNames.count) columns in INSERT")
            }
            var texts = [String](repeating: "", count: definition.columns.count)
            var explicitRowid: Int64?
            for (position, value) in values.enumerated() {
                if position == rowidSlot {
                    explicitRowid = try ftsRowid(value)
                } else if let column = ftsColumnForSlot[position] {
                    texts[column] = ftsText(value)
                }
            }
            let docid: Int64
            if let explicitRowid { docid = explicitRowid } else { docid = try txn.ftsNextRowid(insert.table) }
            try txn.ftsAdd(insert.table, docid: docid, columnTexts: texts)
            changes += 1
            lastRowid = docid
        }

        switch insert.source {
            case .values(let rows):
                for rowExprs in rows {
                    var values: [Value] = []
                    values.reserveCapacity(rowExprs.count)
                    for expr in rowExprs { values.append(try SQLEval.evaluate(expr, paramsEnv)) }
                    try indexRow(values)
                }
            case .select(let select):
                for values in try runSelectInTxn(select, txn: txn, params: params) { try indexRow(values) }
        }
        return ([], RunResult(changes: changes, lastInsertRowid: lastRowid))
    }

    /// The fts5 command idiom (`INSERT INTO fts(fts, …) VALUES('delete'|'delete-all', …)`).
    /// `'delete'` removes the named rowid (driven by the stored forward record);
    /// `'delete-all'` clears the index. Other commands are unsupported.
    private static func ftsCommand(
        _ insert: SQLInsert, txn: borrowing WriteTxn, params: SQLParameters
    ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
        guard case .values(let rows) = insert.source else {
            throw DBError.sqlUnsupported("FTS command requires VALUES")
        }
        let paramsEnv = writeEnv(txn: txn, params: params)
        let rowidPosition = insert.columns.firstIndex { $0.lowercased() == "rowid" }
        var changes = 0
        for rowExprs in rows {
            guard rowExprs.count == insert.columns.count else {
                throw DBError.sqlBind("FTS command: \(rowExprs.count) values for \(insert.columns.count) columns")
            }
            var values: [Value] = []
            values.reserveCapacity(rowExprs.count)
            for expr in rowExprs { values.append(try SQLEval.evaluate(expr, paramsEnv)) }
            guard case .text(let command) = values[0] else {
                throw DBError.sqlBind("FTS command must be a text value")
            }
            switch command {
                case "delete":
                    guard let rowidPosition else {
                        throw DBError.sqlBind("FTS 'delete' requires a rowid column")
                    }
                    if try txn.ftsRemove(insert.table, docid: ftsRowid(values[rowidPosition])) { changes += 1 }
                case "delete-all":
                    try txn.ftsRemoveAll(insert.table)
                default:
                    throw DBError.sqlUnsupported("FTS command '\(command)'")
            }
        }
        return ([], RunResult(changes: changes, lastInsertRowid: 0))
    }

    static func deleteFTS(
        _ delete: SQLDelete, txn: borrowing WriteTxn, params: SQLParameters
    ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
        guard delete.returning.isEmpty else { throw DBError.sqlUnsupported("RETURNING on an FTS table") }
        let paramsEnv = writeEnv(txn: txn, params: params)
        let docids = try ftsDeleteDocids(delete.whereExpr, env: paramsEnv)
        var changes = 0
        for docid in docids where try txn.ftsRemove(delete.table, docid: docid) { changes += 1 }
        return ([], RunResult(changes: changes, lastInsertRowid: 0))
    }

    /// Extracts docids from `WHERE rowid = expr` / `rowid IN (exprs)`; other shapes
    /// are unsupported (apple-docs deletes FTS rows by rowid).
    private static func ftsDeleteDocids(
        _ predicate: SQLExpr?, env: SQLEvalEnv
    ) throws(DBError) -> [Int64] {
        guard let predicate else {
            throw DBError.sqlUnsupported("DELETE FROM fts requires WHERE rowid = …")
        }
        func isRowid(_ expr: SQLExpr) -> Bool {
            if case .column(_, let name, _) = expr { return name.lowercased() == "rowid" }
            return false
        }
        switch predicate {
            case .binary(.eq, let lhs, let rhs):
                if isRowid(lhs) { return [try ftsRowid(try SQLEval.evaluate(rhs, env))] }
                if isRowid(rhs) { return [try ftsRowid(try SQLEval.evaluate(lhs, env))] }
            case .inList(let target, let items, let negated) where !negated && isRowid(target):
                var docids: [Int64] = []
                for item in items { docids.append(try ftsRowid(try SQLEval.evaluate(item, env))) }
                return docids
            default:
                break
        }
        throw DBError.sqlUnsupported("FTS DELETE supports only WHERE rowid = … or rowid IN (…)")
    }

    private static func ftsRowid(_ value: Value) throws(DBError) -> Int64 {
        guard case .integer(let rowid) = value else {
            throw DBError.sqlBind("FTS rowid must be an integer")
        }
        return rowid
    }

    private static func ftsText(_ value: Value) -> String {
        switch value {
            case .text(let text): return text
            case .null: return ""
            case .integer(let v): return String(v)
            case .real(let v): return String(v)
            case .blob: return ""
        }
    }

    /// Phase 1 of UPDATE/DELETE: every rowid (with its current values) whose row
    /// satisfies the predicate, collected before any mutation (Halloween-safe).
    static func collectMatches(
        _ predicate: SQLExpr?, table: TableDefinition, txn: borrowing WriteTxn, params: SQLParameters
    ) throws(DBError) -> [(rowid: Int64, values: [Value])] {
        // Fast path: a `<col> = <const>` / `<col> IN (<const>…)` predicate over any single-column index
        // (unique OR not) seeks the matching rowid(s) instead of scanning the whole table. Without it an
        // UPDATE or DELETE keyed on an indexed column is O(rows) — and O(rows·k) for a k-element IN list,
        // since the list is re-scanned per row — which dominates a point/small-set mutation on a large
        // table (e.g. per-key denormalization: one UPDATE per key × N rows). Each seeked row is re-checked
        // against the FULL predicate, so the result is identical to the scan.
        if let predicate,
            let seeked = try seekIndexedMatches(predicate, table: table, txn: txn, params: params)
        {
            return seeked
        }
        return try txn.withRowCursor(table: table.name) { (cursor) throws(DBError) in
            var matches: [(rowid: Int64, values: [Value])] = []
            while let row = try cursor.next() {
                if let predicate {
                    let env = rowEnv(table: table, values: row.values, params: params, triggerCtx: txn.ctx)
                    if SQLEval.truth(try SQLEval.evaluate(predicate, env)) != .yes { continue }
                }
                matches.append((row.rowid, row.values))
            }
            return matches
        }
    }

    /// The index seek behind `collectMatches`. Returns the matching rows when `predicate` is a `<col> =
    /// <const>` (either operand order) or `<col> IN (<const>…)` over a single-column index — UNIQUE (≤1 row
    /// per value) or not (a value maps to many rows) — whose constants are all TEXT. TEXT-only keeps the
    /// seek exact: a TEXT seek matches a TEXT-stored key with no affinity coercion, so no row the scan
    /// would find is missed. Any other shape/type returns `nil` → the caller scans (correct, unaccelerated).
    private static func seekIndexedMatches(
        _ predicate: SQLExpr, table: TableDefinition, txn: borrowing WriteTxn, params: SQLParameters
    ) throws(DBError) -> [(rowid: Int64, values: [Value])]? {
        guard let (column, values) = try pointPredicate(predicate, table: table, params: params) else {
            return nil
        }
        guard values.allSatisfy({ if case .text = $0 { true } else { false } }) else { return nil }
        guard
            let index = try txn.schema().indexes(on: table.name)
                .first(where: {
                    $0.columns.count == 1 && $0.columns[0].lowercased() == column.lowercased()
                })
        else { return nil }

        var matches: [(rowid: Int64, values: [Value])] = []
        var seen = Set<Int64>()
        for value in values {
            for rowid in try txn.matchingRowids(index: index.name, equals: [value])
            where seen.insert(rowid).inserted {  // dedupe across a repeated IN value
                guard let row = try txn.row(in: table.name, rowid: rowid) else { continue }
                // Re-check the FULL predicate on the candidate — the seek only narrows the search space;
                // the predicate stays the source of truth, so the result is byte-identical to the scan.
                let env = rowEnv(table: table, values: row.values, params: params, triggerCtx: txn.ctx)
                if SQLEval.truth(try SQLEval.evaluate(predicate, env)) != .yes { continue }
                matches.append((rowid, row.values))
            }
        }
        return matches
    }

    /// Destructures `<col> = <const>` (either operand order) or `<col> IN (<const>…)` (not negated) into
    /// the column name + resolved constant values, or `nil` when `predicate` isn't one of those shapes.
    /// Constants are literals or bound parameters; any other operand (a column, an expression) yields nil.
    private static func pointPredicate(
        _ predicate: SQLExpr, table: TableDefinition, params: SQLParameters
    ) throws(DBError) -> (column: String, values: [Value])? {
        switch predicate {
            case .binary(.eq, let lhs, let rhs):
                if let column = columnName(lhs, table: table), let value = try constant(rhs, params) {
                    return (column, [value])
                }
                if let column = columnName(rhs, table: table), let value = try constant(lhs, params) {
                    return (column, [value])
                }
                return nil
            case .inList(let columnExpr, let items, let negated) where !negated:
                guard let column = columnName(columnExpr, table: table), !items.isEmpty else { return nil }
                var values: [Value] = []
                values.reserveCapacity(items.count)
                for item in items {
                    guard let value = try constant(item, params) else { return nil }
                    values.append(value)
                }
                return (column, values)
            default:
                return nil
        }
    }

    /// The column name of a bare column reference (raw `.column` or bind-time `.boundColumn`), else nil.
    private static func columnName(_ expr: SQLExpr, table: TableDefinition) -> String? {
        switch expr {
            case .column(_, let name, _): return name
            case .boundColumn(_, let column):
                return table.columns.indices.contains(column) ? table.columns[column].name : nil
            default: return nil
        }
    }

    /// The value of a constant operand (literal or bound parameter), else nil.
    private static func constant(_ expr: SQLExpr, _ params: SQLParameters) throws(DBError) -> Value? {
        switch expr {
            case .literal(let value): return value
            case .parameter(let param, _): return try params.lookup(param)
            default: return nil
        }
    }
}
