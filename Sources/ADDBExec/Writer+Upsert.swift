@_spi(ADDBEngine) import ADDBCore
import ADSQL
import ADSQLModel

/// ON CONFLICT DO UPDATE (upsert) execution for `Writer`. Split from
/// `Writer.swift` to keep the enum body within the gate.
extension Writer {
    // MARK: - ON CONFLICT DO UPDATE (upsert)

    /// Inserts the candidate row, or — when it conflicts on the target unique
    /// column — applies the DO UPDATE SET against the existing row with the
    /// proposed row visible as `excluded.*`.
    /// The row + target an upsert resolves against: the candidate column values, the
    /// conflict-target column, the DO UPDATE SET assignments, and the table identity
    /// (name + definition + schema).
    struct UpsertRequest {
        let candidate: [String: Value]
        let target: String
        let sets: [SQLAssignment]
        let table: String
        let definition: TableDefinition
        let schema: Schema
    }

    static func applyUpsert(
        _ request: UpsertRequest, txn: borrowing WriteTxn, params: SQLParameters,
        changes: inout Int, lastRowid: inout Int64, record: (Int64) throws(DBError) -> Void
    ) throws(DBError) {
        let candidate = request.candidate
        let target = request.target
        let sets = request.sets
        let table = request.table
        let definition = request.definition
        let schema = request.schema
        let existingRowid: Int64?
        if case .rowidAlias(let aliasColumn, _) = definition.primaryKey, aliasColumn == target {
            if case .integer(let candidateRowid)? = candidate[target],
                try txn.row(in: table, rowid: candidateRowid) != nil
            {
                existingRowid = candidateRowid
            } else {
                existingRowid = nil
            }
        } else {
            guard
                let index = schema.indexes(on: table)
                    .first(where: {
                        $0.unique && $0.columns.count == 1 && $0.columns[0].lowercased() == target.lowercased()
                    })
            else {
                throw DBError.sqlBind("ON CONFLICT target \(target) is not a unique column")
            }
            if let value = candidate[target], !value.isNull {
                existingRowid = try txn.firstRowid(index: index.name, equals: [value])
            } else {
                existingRowid = nil  // NULLs never collide in a unique index
            }
        }

        guard let rowid = existingRowid else {
            if let inserted = try txn.insert(into: table, candidate, onConflict: .abort) {
                changes += 1
                lastRowid = inserted
                try record(inserted)
            }
            return
        }

        guard let existing = try txn.row(in: table, rowid: rowid) else {
            throw DBError.integrityFailure("upsert target row \(rowid) vanished")
        }
        let env = excludedEnv(
            candidate: candidate, existing: existing.values, definition: definition, params: params)
        var setValues: [String: Value] = [:]
        for assignment in sets {
            guard definition.columnIndex(of: assignment.column) != nil else {
                throw DBError.noSuchColumn(table: table, column: assignment.column)
            }
            setValues[assignment.column] = try SQLEval.evaluate(assignment.value, env)
        }
        _ = try txn.update(table, rowid: rowid, set: setValues)
        changes += 1
        lastRowid = rowid
        try record(rowid)
    }

    /// SET-expression env for DO UPDATE: `excluded.col` is the proposed insert
    /// value (or the column default when not supplied); a bare/table-qualified
    /// column is the existing row's value.
    static func excludedEnv(
        candidate: [String: Value], existing: [Value], definition: TableDefinition,
        params: SQLParameters
    ) -> SQLEvalEnv {
        SQLEvalEnv(
            now: params.now,
            parameter: { p throws(DBError) in try params.lookup(p) },
            column: { (qualifier, name, _) throws(DBError) in
                if let qualifier, qualifier.lowercased() == "excluded" {
                    if let value = candidate[name] { return value }
                    guard let column = definition.columns.first(where: { $0.name == name }) else {
                        throw DBError.noSuchColumn(table: "excluded", column: name)
                    }
                    switch column.defaultValue {
                        case .value(let value): return value
                        case .datetimeNow: return .text(CivilTime.utcNowString(now: params.now))
                        case nil: return .null
                    }
                }
                guard let index = definition.columnIndex(of: name) else {
                    throw DBError.noSuchColumn(table: definition.name, column: name)
                }
                return existing[index]
            },
            collationOf: { (_, name) in
                definition.columnIndex(of: name).map { definition.columns[$0].collation }
            },
            columnTypeOf: { (_, name) in
                definition.columnIndex(of: name).map { definition.columns[$0].type }
            },
            scalarSubquery: { _ throws(DBError) in
                throw DBError.sqlUnsupported("subquery in this context")
            })
    }
}
