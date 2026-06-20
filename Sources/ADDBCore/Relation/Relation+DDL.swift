public import ADSQLModel

/// DDL + trigger lifecycle for the relational `Relation` engine (CREATE/DROP TABLE, virtual
/// table, CREATE/DROP TRIGGER), split from `Relation.swift` to keep the enum body within the gate.
@_spi(ADDBEngine) extension Relation {
    // MARK: - DDL

    static func createTable(_ ctx: TxnContext, _ definition: TableDefinition) throws(DBError) {
        try definition.validate()
        var state = try ensureState(ctx)
        guard state.tableRecords[definition.name] == nil, state.ftsRecords[definition.name] == nil else {
            throw DBError.tableExists(definition.name)
        }
        guard definition.name.utf8.count <= 255 else {
            throw DBError.invalidDefinition("table name too long")
        }
        for fk in definition.foreignKeys {
            guard fk.parentTable == definition.name || state.tableRecords[fk.parentTable] != nil else {
                throw DBError.noSuchTable(fk.parentTable)
            }
        }
        let id = state.version.nextTableId
        state.version.nextTableId += 1
        state.tableRecords[definition.name] = Catalog.TableRecord(
            tableId: id, handle: .empty, definition: definition)
        state.handleBaselines[.table(id)] = nil as TreeHandle?
        state.schemaDirty = true
        ctx.relation = state
    }

    /// Creates an FTS virtual table: a catalog record owning three (initially
    /// empty) B+trees. Roots are allocated lazily on first write, exactly
    /// like a table/index handle. No indexing here — is foundations only.
    static func createVirtualTable(_ ctx: TxnContext, _ definition: FTSDefinition) throws(DBError) {
        var state = try ensureState(ctx)
        guard state.tableRecords[definition.name] == nil, state.ftsRecords[definition.name] == nil else {
            throw DBError.tableExists(definition.name)
        }
        guard definition.name.utf8.count <= 255 else {
            throw DBError.invalidDefinition("virtual table name too long")
        }
        guard !definition.columns.isEmpty else {
            throw DBError.invalidDefinition("fts5 table \(definition.name) has no columns")
        }
        for column in definition.columns where column.utf8.count > 255 {
            throw DBError.invalidDefinition("fts5 table \(definition.name): column name too long")
        }
        for token in definition.tokenize where token.utf8.count > 255 {
            throw DBError.invalidDefinition("fts5 table \(definition.name): tokenizer argument too long")
        }
        if case .external(let table, let rowid) = definition.content {
            guard table.utf8.count <= 255, rowid.utf8.count <= 255 else {
                throw DBError.invalidDefinition(
                    "fts5 table \(definition.name): content table/rowid name too long")
            }
        }
        let id = state.version.nextTableId
        state.version.nextTableId += 1
        state.ftsRecords[definition.name] = Catalog.FTSRecord(
            ftsId: id, dict: .empty, postings: .empty, stats: .empty, definition: definition)
        state.handleBaselines[.ftsDict(id)] = nil as TreeHandle?
        state.handleBaselines[.ftsPostings(id)] = nil as TreeHandle?
        state.handleBaselines[.ftsStats(id)] = nil as TreeHandle?
        state.schemaDirty = true
        ctx.relation = state
    }

    static func dropTable(_ ctx: TxnContext, name: String) throws(DBError) {
        var state = try ensureState(ctx)
        guard let record = state.tableRecords[name] else {
            // `DROP TABLE` also removes an FTS virtual table.
            if state.ftsRecords[name] != nil { return try dropVirtualTable(ctx, name: name) }
            throw DBError.noSuchTable(name)
        }
        // Another table referencing this one blocks the drop.
        for (otherName, other) in state.tableRecords where otherName != name {
            if other.definition.foreignKeys.contains(where: { $0.parentTable == name }) {
                throw DBError.foreignKeyViolation(table: otherName)
            }
        }
        var main = ctx.meta.mainTree

        let ownIndexes = state.indexRecords.filter { $0.value.tableId == record.tableId }
        for (indexName, indexRecord) in ownIndexes.sorted(by: { $0.key < $1.key }) {
            try freeTree(ctx, handle: indexRecord.handle)
            try deleteBytes(ctx, &main, key: Catalog.indexKey(indexName))
            state.indexRecords.removeValue(forKey: indexName)
            state.handleBaselines.removeValue(forKey: .index(indexRecord.indexId))
        }
        try freeTree(ctx, handle: record.handle)
        try deleteBytes(ctx, &main, key: Catalog.tableKey(name))
        try deleteBytes(ctx, &main, key: Catalog.sequenceKey(record.tableId))
        state.tableRecords.removeValue(forKey: name)
        state.handleBaselines.removeValue(forKey: .table(record.tableId))
        state.sequences.removeValue(forKey: record.tableId)
        state.sequenceBaselines.removeValue(forKey: record.tableId)
        state.maxRowidCache.removeValue(forKey: record.tableId)
        // Triggers on this table go with it (SQLite drops dependent triggers). The
        // SQL engine reports which stored triggers target this table.
        for triggerName in try ctx.triggerNamesTargeting(name) {
            state.triggerTexts.removeValue(forKey: triggerName)
            state.triggerWrites[triggerName] = nil as String?
        }
        state.schemaDirty = true
        ctx.hoistedRoster.removeAll(keepingCapacity: true)

        ctx.meta.mainTree = main
        ctx.relation = state
    }

    /// Drops an FTS virtual table and frees the three trees it owns.
    static func dropVirtualTable(_ ctx: TxnContext, name: String) throws(DBError) {
        var state = try ensureState(ctx)
        guard let record = state.ftsRecords[name] else { throw DBError.noSuchTable(name) }
        var main = ctx.meta.mainTree
        try freeTree(ctx, handle: record.dict)
        try freeTree(ctx, handle: record.postings)
        try freeTree(ctx, handle: record.stats)
        try deleteBytes(ctx, &main, key: Catalog.ftsKey(name))
        state.ftsRecords.removeValue(forKey: name)
        state.handleBaselines.removeValue(forKey: .ftsDict(record.ftsId))
        state.handleBaselines.removeValue(forKey: .ftsPostings(record.ftsId))
        state.handleBaselines.removeValue(forKey: .ftsStats(record.ftsId))
        state.schemaDirty = true
        ctx.meta.mainTree = main
        ctx.relation = state
    }

    // MARK: - Triggers

    /// Registers a trigger: validates its name (unique across the table/index/
    /// fts/trigger namespace) and its target (an existing base table), then
    /// records it for write-back as raw CREATE TRIGGER text. No firing here —
    /// the DML path looks triggers up by (table, event) when rows change.
    static func createTrigger(
        _ ctx: TxnContext, name: String, table: String, sql: String
    ) throws(DBError) {
        var state = try ensureState(ctx)
        guard name.utf8.count <= 255 else {
            throw DBError.invalidDefinition("trigger name too long")
        }
        guard state.triggerTexts[name] == nil else {
            throw DBError.triggerExists(name)
        }
        // Shared schema namespace (SQLite keeps triggers alongside tables/indexes).
        guard state.tableRecords[name] == nil,
            state.indexRecords[name] == nil,
            state.ftsRecords[name] == nil
        else {
            throw DBError.invalidDefinition("object named \(name) already exists")
        }
        // The SQL layer supplies the already-parsed target table, so storage
        // enforces "target exists / not a virtual table" without parsing.
        guard state.tableRecords[table] != nil else {
            if state.ftsRecords[table] != nil {
                throw DBError.invalidDefinition("cannot create trigger on virtual table \(table)")
            }
            throw DBError.noSuchTable(table)
        }
        state.triggerTexts[name] = sql
        state.triggerWrites[name] = sql
        state.schemaDirty = true
        ctx.relation = state
    }

    static func dropTrigger(_ ctx: TxnContext, name: String) throws(DBError) {
        var state = try ensureState(ctx)
        guard state.triggerTexts[name] != nil else { throw DBError.noSuchTrigger(name) }
        state.triggerTexts.removeValue(forKey: name)
        state.triggerWrites[name] = nil as String?
        state.schemaDirty = true
        ctx.relation = state
    }

    /// Single-record catalog fetches (read paths avoid full catalog loads).
    @_spi(ADDBEngine) public static func tableRecord(
        _ resolver: some PageResolver, mainTree: TreeHandle, name: String
    ) throws(DBError) -> Catalog.TableRecord? {
        guard let bytes = try getBytes(resolver, mainTree, key: Catalog.tableKey(name)) else {
            return nil
        }
        var result: Result<Catalog.TableRecord, DBError> = .failure(.noSuchTable(name))
        bytes.withUnsafeBytes { raw in
            do throws(DBError) {
                result = unsafe .success(try Catalog.decodeTable(raw, name: name))
            } catch {
                result = .failure(error)
            }
        }
        return try result.get()
    }

    @_spi(ADDBEngine) public static func indexRecord(
        _ resolver: some PageResolver, mainTree: TreeHandle, name: String
    ) throws(DBError) -> Catalog.IndexRecord? {
        guard let bytes = try getBytes(resolver, mainTree, key: Catalog.indexKey(name)) else {
            return nil
        }
        var result: Result<Catalog.IndexRecord, DBError> = .failure(.noSuchIndex(name))
        bytes.withUnsafeBytes { raw in
            do throws(DBError) {
                result = unsafe .success(try Catalog.decodeIndex(raw, name: name))
            } catch {
                result = .failure(error)
            }
        }
        return try result.get()
    }

    /// Single-record FTS catalog fetch (the read path resolves an FTS table's
    /// dictionary/postings/stats roots without a full catalog load), mirroring
    /// `tableRecord`/`indexRecord`. nil when the FTS table is absent.
    @_spi(ADDBEngine) public static func ftsRecord(
        _ resolver: some PageResolver, mainTree: TreeHandle, name: String
    ) throws(DBError) -> Catalog.FTSRecord? {
        guard let bytes = try getBytes(resolver, mainTree, key: Catalog.ftsKey(name)) else {
            return nil
        }
        var result: Result<Catalog.FTSRecord, DBError> = .failure(.noSuchTable(name))
        bytes.withUnsafeBytes { raw in
            do throws(DBError) {
                result = unsafe .success(try Catalog.decodeFTS(raw, name: name))
            } catch {
                result = .failure(error)
            }
        }
        return try result.get()
    }
}
