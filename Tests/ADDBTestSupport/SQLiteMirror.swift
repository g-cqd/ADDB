package import ADDBCore
import CSQLite

// MARK: - SQLite mirror (full-query oracle)

/// A `:memory:` SQLite database used as the differential oracle for SELECT /
/// MATCH execution: same DDL + data, same queries, compared result sets. Shared
/// across the SQL and full-text-search test targets, so it lives in the common
/// test-support target rather than any one suite.
package final class SQLiteMirror {
    package var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    package init() {
        precondition(
            sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
    }
    deinit { sqlite3_close_v2(db) }

    package func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DBError.sqlRuntime("sqlite exec: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    package func insertRow(_ table: String, _ columns: [String], _ values: [Value]) throws {
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
        let sql = "INSERT INTO \(table)(\(columns.joined(separator: ","))) VALUES(\(placeholders))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sqlRuntime("sqlite prepare: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.sqlRuntime("sqlite insert: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    package func query(_ sql: String, _ params: [Value] = []) throws -> [[Value]] {
        try query(sql) { stmt in bind(stmt, params) }
    }

    /// Runs `sql` binding `$name` parameters by name.
    package func query(_ sql: String, named: [String: Value]) throws -> [[Value]] {
        let transient = self.transient
        return try query(sql) { stmt in
            for (name, value) in named {
                let index = sqlite3_bind_parameter_index(stmt, "$\(name)")
                guard index > 0 else { continue }
                switch value {
                case .null: sqlite3_bind_null(stmt, index)
                case .integer(let v): sqlite3_bind_int64(stmt, index, v)
                case .real(let d): sqlite3_bind_double(stmt, index, d)
                case .text(let s): sqlite3_bind_text(stmt, index, s, -1, transient)
                case .blob(let b):
                    b.withUnsafeBytes {
                        _ = sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(b.count), transient)
                    }
                }
            }
        }
    }

    private func query(_ sql: String, _ binder: (OpaquePointer?) -> Void) throws -> [[Value]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sqlRuntime("sqlite prepare: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        binder(stmt)
        var rows: [[Value]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let columns = sqlite3_column_count(stmt)
            var row: [Value] = []
            row.reserveCapacity(Int(columns))
            for index in 0..<columns { row.append(columnValue(stmt, index)) }
            rows.append(row)
        }
        return rows
    }

    private func bind(_ stmt: OpaquePointer?, _ values: [Value]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(stmt, index)
            case .integer(let v): sqlite3_bind_int64(stmt, index, v)
            case .real(let d): sqlite3_bind_double(stmt, index, d)
            case .text(let s): sqlite3_bind_text(stmt, index, s, -1, transient)
            case .blob(let b):
                b.withUnsafeBytes {
                    _ = sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(b.count), transient)
                }
            }
        }
    }

    private func columnValue(_ stmt: OpaquePointer?, _ index: Int32) -> Value {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(stmt, index))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(stmt, index)))
        default:
            let count = Int(sqlite3_column_bytes(stmt, index))
            guard count > 0, let base = sqlite3_column_blob(stmt, index) else { return .blob([]) }
            return .blob([UInt8](UnsafeRawBufferPointer(start: base, count: count)))
        }
    }
}

// MARK: - Result-set comparison

package func valueMatches(_ a: Value, _ b: Value) -> Bool {
    if a == b { return true }
    if case .real(let x) = a, case .real(let y) = b { return x == y || (x.isNaN && y.isNaN) }
    return false
}

package func rowsMatch(_ ours: [[Value]], _ theirs: [[Value]], ordered: Bool) -> Bool {
    guard ours.count == theirs.count else { return false }
    let lhs = ordered ? ours : ours.sorted { lexLess($0, $1) }
    let rhs = ordered ? theirs : theirs.sorted { lexLess($0, $1) }
    for (a, b) in zip(lhs, rhs) {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where !valueMatches(x, y) { return false }
    }
    return true
}

/// Deterministic total order for multiset comparison (oracle-only).
package func lexLess(_ a: [Value], _ b: [Value]) -> Bool {
    for i in 0..<min(a.count, b.count) {
        let c = Value.keyOrder(a[i], b[i])
        if c != 0 { return c < 0 }
    }
    return a.count < b.count
}
