import ADSQLModel

/// One index whose entry a row `update` must rewrite: its old/new encoded keys and whether the key
/// (not just a covering INCLUDE value) changed.
private struct ChangedIndex {
    let name: String
    let oldKey: [UInt8]
    let newKey: [UInt8]
    let keyChanged: Bool
}

/// Row delete + update for the storage layer (split from
/// DML.swift). `deleteRowCore`/`delete` (the physical single-row delete with index
/// maintenance + ON DELETE cascade/restrict actions) and the two-phase row
/// `update` (index + FK upkeep). An `extension Relation`; code motion + visibility.
extension Relation {
    /// Physical single-row delete + index maintenance (no FK actions).
    @discardableResult
    static func deleteRowCore(
        _ ctx: TxnContext, from tableName: String, rowid: Int64
    ) throws(DBError) -> Bool {
        var state = try ensureState(ctx)
        guard var table = state.tableRecords[tableName] else {
            throw DBError.noSuchTable(tableName)
        }
        guard let recordBytes = try getBytes(ctx, table.handle, key: KeyCodec.rowKey(rowid)) else {
            return false
        }
        let row = try materializeRow(table: table, rowid: rowid, recordBytes: recordBytes)

        for indexName in state.indexRecords.keys.sorted() where state.indexRecords[indexName]!.tableId == table.tableId
        {
            var index = state.indexRecords[indexName]!
            let key = try indexEntryKey(index: index, table: table, row: row, rowid: rowid)
            var indexHandle = index.handle
            let removed = try deleteBytes(ctx, &indexHandle, key: key)
            guard removed else {
                throw DBError.integrityFailure(
                    "index \(indexName) missing entry for \(tableName) rowid \(rowid)")
            }
            index.handle = indexHandle
            state.indexRecords[indexName] = index
        }

        var handle = table.handle
        _ = try deleteBytes(ctx, &handle, key: KeyCodec.rowKey(rowid))
        table.handle = handle
        state.tableRecords[tableName] = table
        // The deleted row may have been the max rowid; a plain rowid table reuses it,
        // so drop the cache and let the next allocation re-probe (matches SQLite).
        state.maxRowidCache[table.tableId] = nil
        ctx.relation = state
        // AFTER DELETE row triggers: OLD = the removed row. Fires for direct
        // deletes, FK cascades, and OR REPLACE victims (all route through here),
        // matching SQLite.
        try ctx.fireTriggers(event: .delete, table: tableName, old: row, new: nil)
        return true
    }

    /// Row delete with ON DELETE actions (cascade chains, restrict checks).
    @discardableResult
    static func delete(
        _ ctx: TxnContext, from tableName: String, rowid: Int64
    ) throws(DBError) -> Bool {
        guard try deleteRowCore(ctx, from: tableName, rowid: rowid) else { return false }
        try processDeleteActions(ctx, deleted: [(table: tableName, rowid: rowid)])
        return true
    }

    // MARK: - Update

    @discardableResult
    static func update(
        _ ctx: TxnContext, table tableName: String, rowid: Int64, set: [String: Value]
    ) throws(DBError) -> Bool {
        var state = try ensureState(ctx)
        guard var table = state.tableRecords[tableName] else {
            throw DBError.noSuchTable(tableName)
        }
        let definition = table.definition
        guard let recordBytes = try getBytes(ctx, table.handle, key: KeyCodec.rowKey(rowid)) else {
            return false
        }
        let oldRow = try materializeRow(table: table, rowid: rowid, recordBytes: recordBytes)

        var newRow = oldRow
        // Schema indices this UPDATE actually assigns, collected as the SET is applied.
        // An index none of whose key/INCLUDE columns lie in this set reads only cells
        // that oldRow and newRow share, so its entry is byte-identical — re-keying it
        // is skipped below (see the roster loop).
        var changedColumns = Set<Int>()
        for (name, provided) in set {
            guard let columnIndex = definition.columnIndex(of: name) else {
                throw DBError.noSuchColumn(table: tableName, column: name)
            }
            if columnIndex == definition.rowidAliasIndex {
                throw DBError.invalidDefinition(
                    "updating the rowid alias is unsupported; delete and reinsert")
            }
            let column = definition.columns[columnIndex]
            var value = provided
            if case .real(let d) = value, d.isNaN { value = .null }
            if !value.isNull, let type = value.columnType, type != column.type {
                throw DBError.typeMismatch(
                    table: tableName, column: name, expected: column.type.name, got: value.typeName)
            }
            if value.isNull && column.notNull {
                throw DBError.notNullViolation(table: tableName, column: name)
            }
            newRow[columnIndex] = value
            changedColumns.insert(columnIndex)
        }

        // Index maintenance for changed keys only, with unique pre-checks. The roster
        // is hoisted (cached per (txn, tableId)) rather than filtered + sorted per row.
        let ownIndexNames = ownedIndexNames(ctx, state: state, tableId: table.tableId)
        // An entry is rewritten when its key changes, or — for a covering index —
        // when only its stored INCLUDE value changes (key-stable, value-only update).
        var changedIndexes: [ChangedIndex] = []
        for indexName in ownIndexNames {
            let index = state.indexRecords[indexName]!
            // Skip an index whose key + INCLUDE columns the SET does not touch: its
            // entry is a pure function of unchanged cells and the fixed rowid, so old
            // and new keys/values are identical — encoding them would be dead work (the
            // `keyChanged || valueChanged` guard below would drop it anyway). Columns are
            // resolved through `columnIndex(of:)`, exactly as `indexEntryKey` reads them.
            let touched =
                index.definition.columns.contains {
                    changedColumns.contains(definition.columnIndex(of: $0)!)
                }
                || index.definition.includes.contains {
                    changedColumns.contains(definition.columnIndex(of: $0)!)
                }
            guard touched else { continue }
            let oldKey = try indexEntryKey(index: index, table: table, row: oldRow, rowid: rowid)
            let newKey = try indexEntryKey(index: index, table: table, row: newRow, rowid: rowid)
            let keyChanged = oldKey != newKey
            let valueChanged =
                !index.definition.includes.isEmpty
                && indexEntryValue(index: index, table: table, row: oldRow)
                    != indexEntryValue(index: index, table: table, row: newRow)
            guard keyChanged || valueChanged else { continue }
            if keyChanged, index.definition.unique,
                try uniqueConflict(ctx, index: index, table: table, row: newRow, excluding: rowid) != nil
            {
                throw DBError.uniqueViolation(table: tableName, index: indexName)
            }
            changedIndexes.append(
                ChangedIndex(name: indexName, oldKey: oldKey, newKey: newKey, keyChanged: keyChanged))
        }

        for change in changedIndexes {
            var index = state.indexRecords[change.name]!
            var indexHandle = index.handle
            if change.keyChanged {
                let removed = try deleteBytes(ctx, &indexHandle, key: change.oldKey)
                guard removed else {
                    throw DBError.integrityFailure(
                        "index \(change.name) missing entry for \(tableName) rowid \(rowid)")
                }
            }
            // Key-stable value updates overwrite in place (BTree.put replaces on an
            // exact key match), so no delete is needed in that case.
            try putBytes(
                ctx, &indexHandle, key: change.newKey,
                value: indexEntryValue(index: index, table: table, row: newRow))
            index.handle = indexHandle
            state.indexRecords[change.name] = index
        }

        var handle = table.handle
        try putBytes(ctx, &handle, key: KeyCodec.rowKey(rowid), value: RecordCodec.encode(newRow))
        table.handle = handle
        state.tableRecords[tableName] = table
        ctx.relation = state
        // AFTER UPDATE row triggers: OLD = pre-update row, NEW = post-update row.
        try ctx.fireTriggers(event: .update, table: tableName, old: oldRow, new: newRow)
        return true
    }
}
