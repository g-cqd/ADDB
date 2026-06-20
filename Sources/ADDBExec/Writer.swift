@_spi(ADDBEngine) import ADDBCore
import ADSQL
import ADSQLModel

/// SQL write execution over a `WriteTxn`: INSERT/UPDATE/DELETE plus DDL. Each
/// reuses the relational engine (strict typing, conflict policies, index
/// maintenance, FK actions) and the SQL evaluator for VALUES/SET/WHERE/
/// RETURNING expressions. UPDATE and DELETE are two-phase (collect matching
/// rowids, then mutate) to avoid mutating a tree under its own cursor.
enum Writer {
    static func execute(
        _ ast: SQLStatementAST, txn: borrowing WriteTxn, params: SQLParameters
    ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
        switch ast {
            case .insert(let insert):
                return try self.insert(insert, txn: txn, params: params)
            case .update(let update):
                return try self.update(update, txn: txn, params: params)
            case .delete(let delete):
                return try self.delete(delete, txn: txn, params: params)
            case .createTable(let create):
                try createTable(create, txn: txn)
                return ([], RunResult())
            case .createVirtualTable(let create):
                try createVirtualTable(create, txn: txn)
                return ([], RunResult())
            case .createIndex(let create):
                try createIndex(create, txn: txn)
                return ([], RunResult())
            case .createTrigger(let create):
                try createTrigger(create, txn: txn)
                return ([], RunResult())
            case .dropTable(let name, let ifExists):
                try dropTable(name, ifExists: ifExists, txn: txn)
                return ([], RunResult())
            case .dropIndex(let name, let ifExists):
                try dropIndex(name, ifExists: ifExists, txn: txn)
                return ([], RunResult())
            case .dropTrigger(let name, let ifExists):
                try dropTrigger(name, ifExists: ifExists, txn: txn)
                return ([], RunResult())
            case .select, .pragma, .begin, .commit, .rollback:
                throw DBError.sqlUnsupported("not a write statement")
        }
    }

    // MARK: - DDL

    static func createTable(_ create: SQLCreateTable, txn: borrowing WriteTxn) throws(DBError) {
        let schema = try txn.schema()
        if schema.tables[create.definition.name] != nil || schema.ftsTables[create.definition.name] != nil {
            if create.ifNotExists { return }
            throw DBError.invalidDefinition("table \(create.definition.name) already exists")
        }
        try txn.createTable(create.definition)
        for index in create.impliedIndexes { try txn.createIndex(index) }
    }

    static func createVirtualTable(
        _ create: SQLCreateVirtualTable, txn: borrowing WriteTxn
    ) throws(DBError) {
        let schema = try txn.schema()
        if schema.tables[create.definition.name] != nil || schema.ftsTables[create.definition.name] != nil {
            if create.ifNotExists { return }
            throw DBError.invalidDefinition("table \(create.definition.name) already exists")
        }
        try txn.createVirtualTable(create.definition)
    }

    static func createIndex(_ create: SQLCreateIndex, txn: borrowing WriteTxn) throws(DBError) {
        if try txn.schema().indexes[create.definition.name] != nil {
            if create.ifNotExists { return }
            throw DBError.invalidDefinition("index \(create.definition.name) already exists")
        }
        try txn.createIndex(create.definition)
    }

    static func createTrigger(
        _ create: SQLCreateTrigger, txn: borrowing WriteTxn
    ) throws(DBError) {
        if try txn.schema().triggerTexts[create.definition.name] != nil {
            if create.ifNotExists { return }
            throw DBError.triggerExists(create.definition.name)
        }
        try txn.createTrigger(
            name: create.definition.name, table: create.definition.table, sql: create.definition.sql)
    }

    static func dropTrigger(_ name: String, ifExists: Bool, txn: borrowing WriteTxn) throws(DBError) {
        if try txn.schema().triggerTexts[name] == nil {
            if ifExists { return }
            throw DBError.noSuchTrigger(name)
        }
        try txn.dropTrigger(name)
    }

    static func dropTable(_ name: String, ifExists: Bool, txn: borrowing WriteTxn) throws(DBError) {
        let schema = try txn.schema()
        if schema.tables[name] == nil, schema.ftsTables[name] == nil {
            if ifExists { return }
            throw DBError.noSuchTable(name)
        }
        try txn.dropTable(name)
    }

    static func dropIndex(_ name: String, ifExists: Bool, txn: borrowing WriteTxn) throws(DBError) {
        if try txn.schema().indexes[name] == nil {
            if ifExists { return }
            throw DBError.noSuchIndex(name)
        }
        try txn.dropIndex(name)
    }

    // MARK: - INSERT

    /// Resolves an INSERT's ON CONFLICT clause into the engine conflict policy plus,
    /// for DO UPDATE, the validated (target, sets) upsert spec.
    private static func resolveConflict(
        _ insert: SQLInsert, definition: TableDefinition
    ) throws(DBError) -> (policy: ConflictPolicy, upsert: (target: String, sets: [SQLAssignment])?) {
        switch insert.conflict {
            case .abort: return (.abort, nil)
            case .replace: return (.replace, nil)
            case .ignore: return (.ignore, nil)
            case .doUpdate(let target, let sets):
                guard definition.columnIndex(of: target) != nil else {
                    throw DBError.noSuchColumn(table: insert.table, column: target)
                }
                return (.abort, (target, sets))
        }
    }

    static func insert(
        _ insert: SQLInsert, txn: borrowing WriteTxn, params: SQLParameters
    ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
        let schema = try txn.schema()
        if schema.ftsTables[insert.table] != nil {
            return try insertFTS(insert, txn: txn, params: params)
        }
        guard let definition = schema.tables[insert.table] else {
            throw DBError.noSuchTable(insert.table)
        }
        let (conflict, upsert) = try resolveConflict(insert, definition: definition)

        let columnNames = insert.columns.isEmpty ? definition.columns.map(\.name) : insert.columns
        var columnSlots: [Int] = []
        columnSlots.reserveCapacity(columnNames.count)
        for name in columnNames {
            guard let slot = definition.columnIndex(of: name) else {
                throw DBError.noSuchColumn(table: insert.table, column: name)
            }
            columnSlots.append(slot)
        }

        let paramsEnv = writeEnv(txn: txn, params: params)
        let returning = try bindReturning(insert.returning, definition: definition)
        let header = returning.map { SQLColumnHeader($0.map(\.name)) }
        var returningRows: [SQLRow] = []
        var changes = 0
        var lastRowid: Int64 = 0

        func recordReturning(rowid: Int64) throws(DBError) {
            guard let returning, let header else { return }
            guard let row = try txn.row(in: insert.table, rowid: rowid) else {
                throw DBError.integrityFailure("RETURNING row \(rowid) vanished")
            }
            returningRows.append(
                try projectRow(returning, table: definition, values: row.values, header: header, params: params))
        }

        func insertRow(_ rowValues: [Value]) throws(DBError) {
            guard rowValues.count == columnNames.count else {
                throw DBError.sqlBind(
                    "\(rowValues.count) values for \(columnNames.count) columns in INSERT")
            }
            if let upsert {
                let values = Dictionary(uniqueKeysWithValues: zip(columnNames, rowValues))
                try applyUpsert(
                    UpsertRequest(
                        candidate: values, target: upsert.target, sets: upsert.sets,
                        table: insert.table, definition: definition, schema: schema),
                    txn: txn, params: params,
                    changes: &changes, lastRowid: &lastRowid, record: recordReturning)
                return
            }
            guard
                let rowid = try txn.insertAssembled(
                    into: insert.table, columnSlots: columnSlots, values: rowValues, onConflict: conflict)
            else {
                return  // OR IGNORE skipped a conflicting row
            }
            changes += 1
            lastRowid = rowid
            try recordReturning(rowid: rowid)
        }

        switch insert.source {
            case .values(let rows):
                for rowExprs in rows {
                    var rowValues: [Value] = []
                    rowValues.reserveCapacity(rowExprs.count)
                    for expr in rowExprs { rowValues.append(try SQLEval.evaluate(expr, paramsEnv)) }
                    try insertRow(rowValues)
                }
            case .select(let select):
                // Materialize the full result first (Halloween-safe for INSERT … SELECT
                // reading the target table), then insert positionally.
                for rowValues in try runSelectInTxn(select, txn: txn, params: params) {
                    try insertRow(rowValues)
                }
        }
        return (returningRows, RunResult(changes: changes, lastInsertRowid: lastRowid))
    }

    // MARK: - Reading within a write transaction (INSERT … SELECT, subqueries)

    /// Binds and runs a SELECT/compound over a write transaction's own state,
    /// returning fully materialized rows.
    static func runSelectInTxn(
        _ select: SQLSelect, txn: borrowing WriteTxn, params: SQLParameters
    ) throws(DBError) -> [[Value]] {
        switch try Binder.bindQuery(select, schema: try txn.schema()) {
            case .select(let plan):
                return try runBoundSelect(plan, txn: txn, params: params).map(\.values)
            case .compound(let compound):
                var combined: [[Value]] = []
                for (position, arm) in compound.arms.enumerated() {
                    let armRows = try runBoundSelect(arm.select, txn: txn, params: params).map(\.values)
                    if position == 0 {
                        combined = armRows
                    } else if arm.op == .unionAll {
                        combined += armRows
                    } else {
                        combined = SelectExecutor.distinctRows(
                            combined + armRows, collations: compound.outputCollations)
                    }
                }
                return try SelectExecutor.finishCompound(combined, compound: compound, params: params)
                    .map(\.values)
        }
    }

    private static func runBoundSelect(
        _ plan: BoundSelect, txn: borrowing WriteTxn, params: SQLParameters
    ) throws(DBError) -> [SQLRow] {
        var tables: [Catalog.TableRecord] = []
        for binding in plan.binding.tables { tables.append(try txn.tableRecord(binding.table)) }
        var index: Catalog.IndexRecord?
        if let name = plan.access.indexName { index = try txn.indexRecord(name) }
        var joinIndexes: [Catalog.IndexRecord?] = []
        for join in plan.joins {
            if let name = join.access.indexName {
                joinIndexes.append(try txn.indexRecord(name))
            } else {
                joinIndexes.append(nil)
            }
        }
        return try SelectExecutor.run(
            plan, tables: tables, index: index, joinIndexes: joinIndexes, resolver: txn.ctx, params: params)
    }

    // MARK: - UPDATE (two-phase)

    static func update(
        _ update: SQLUpdate, txn: borrowing WriteTxn, params: SQLParameters
    ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
        let schema = try txn.schema()
        guard let definition = schema.tables[update.table] else {
            throw DBError.noSuchTable(update.table)
        }
        for assignment in update.sets where definition.columnIndex(of: assignment.column) == nil {
            throw DBError.noSuchColumn(table: update.table, column: assignment.column)
        }
        let returning = try bindReturning(update.returning, definition: definition)
        let header = returning.map { SQLColumnHeader($0.map(\.name)) }

        // Phase 1: collect matching rows (the predicate sees pre-update values).
        let matches = try collectMatches(update.whereExpr, table: definition, txn: txn, params: params)

        // Phase 2: apply SET (evaluated against each row's pre-update values).
        var returningRows: [SQLRow] = []
        var changes = 0
        for match in matches {
            let env = rowEnv(
                table: definition, values: match.values, params: params, triggerCtx: txn.ctx)
            var assignments: [String: Value] = [:]
            for set in update.sets { assignments[set.column] = try SQLEval.evaluate(set.value, env) }
            guard try txn.update(update.table, rowid: match.rowid, set: assignments) else { continue }
            changes += 1
            if let returning, let header {
                guard let row = try txn.row(in: update.table, rowid: match.rowid) else { continue }
                returningRows.append(
                    try projectRow(returning, table: definition, values: row.values, header: header, params: params))
            }
        }
        return (returningRows, RunResult(changes: changes, lastInsertRowid: 0))
    }

    // MARK: - DELETE (two-phase)

    static func delete(
        _ delete: SQLDelete, txn: borrowing WriteTxn, params: SQLParameters
    ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
        let schema = try txn.schema()
        if schema.ftsTables[delete.table] != nil {
            return try deleteFTS(delete, txn: txn, params: params)
        }
        guard let definition = schema.tables[delete.table] else {
            throw DBError.noSuchTable(delete.table)
        }
        let returning = try bindReturning(delete.returning, definition: definition)
        let header = returning.map { SQLColumnHeader($0.map(\.name)) }

        let matches = try collectMatches(delete.whereExpr, table: definition, txn: txn, params: params)

        // RETURNING reports the pre-delete row, so project before deleting.
        var returningRows: [SQLRow] = []
        if let returning, let header {
            for match in matches {
                returningRows.append(
                    try projectRow(returning, table: definition, values: match.values, header: header, params: params))
            }
        }
        var changes = 0
        for match in matches where try txn.delete(from: delete.table, rowid: match.rowid) {
            changes += 1
        }
        return (returningRows, RunResult(changes: changes, lastInsertRowid: 0))
    }
}
