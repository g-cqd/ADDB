/// The SQL trigger engine: parses, gates, and fires row triggers. After a
/// base-table INSERT/UPDATE/DELETE writes a row (and its secondary-index
/// entries), the storage DML path calls `fire` through the `TriggerFiring`
/// hook with the affected row(s). The engine looks up the table's AFTER
/// triggers for that event, evaluates each `WHEN`, and runs the body
/// INSERT/DELETE/UPDATE statements through the ordinary `Writer` executors with
/// `NEW`/`OLD` bound — inside the *same* write transaction, so FTS-sync triggers
/// keep an external index in step atomically.
///
/// The catalog stores only the raw CREATE TRIGGER text; the engine parses it on
/// demand and caches the parsed definitions per write transaction (so a bulk
/// INSERT firing the same trigger parses once). A depth guard bounds
/// trigger→DML→trigger chains: a self-referential trigger errors instead of
/// looping. Recursion is permitted up to `maxDepth` (the FTS sync chains are
/// depth 1).
final class SQLTriggerEngine: TriggerFiring {
    /// The single stateless engine. State (the parsed-trigger cache) lives on the
    /// write `TxnContext`, so one shared instance serves every database.
    static let shared = SQLTriggerEngine()

    /// Maximum trigger recursion depth — a runaway self-referential trigger trips
    /// this with a clean error instead of overflowing the stack. Each level
    /// re-enters the *full* write executor (`fire` → `Writer.execute` → DML →
    /// `fire`), a far larger per-level frame than SQLite's; the cap is set by the
    /// writer's stack, not by SQLite parity.
    ///
    /// Write execution runs on `WriterThread`, a dedicated pthread with a
    /// `WriterThread.stackSize` (16 MiB) stack, so depth is decoupled from the
    /// caller's stack. Measured per-level growth (one full executor cycle):
    /// ~29.0 KiB in a debug build, ~33.7 KiB under ThreadSanitizer (the worst
    /// case). At depth 100 that peaks at ~3.3 MiB ≈ 20% of the 16 MiB stack — a
    /// ~4.9× margin. The deep-but-bounded test (`deepTriggerChainCompletes`)
    /// actually nests `maxDepth` levels under both debug and TSan and completes,
    /// which is the real proof the headroom exists (a stack overflow is a hard
    /// crash that cannot be caught).
    ///
    /// SQLite-parity recursion (1000) is reachable by raising the single
    /// `WriterThread.stackSize` constant; it remains a knob.
    static let maxDepth: UInt32 = 100

    // MARK: - TriggerFiring

    /// Fires every AFTER trigger registered for `(table, event)`, in name order,
    /// against the supplied NEW/OLD row. No-op when the table has no such trigger
    /// (the common case — a single dictionary-empty check on the cached schema).
    func fire(
        _ ctx: TxnContext, event: TriggerEvent, table tableName: String,
        old: [Value]?, new: [Value]?
    ) throws(DBError) {
        let state = try Relation.ensureState(ctx)
        guard !state.triggerTexts.isEmpty else { return }
        let triggers = try Self.matching(ctx, state: state, table: tableName, event: event)
        guard !triggers.isEmpty else { return }
        guard let definition = state.tableRecords[tableName]?.definition else { return }

        guard ctx.triggerDepth < Self.maxDepth else {
            throw DBError.sqlRuntime("too many levels of trigger recursion")
        }
        let frame = TriggerFrame(table: definition, new: new, old: old)

        // Save/restore the surrounding frame + depth so nested firings compose.
        let savedFrame = ctx.triggerFrame
        ctx.triggerDepth += 1
        defer {
            ctx.triggerFrame = savedFrame
            ctx.triggerDepth -= 1
        }

        let emptyParams = SQLParameters()
        for trigger in triggers {
            ctx.triggerFrame = frame
            if let whenExpr = trigger.whenExpr {
                let env = Self.bodyEnv(ctx, params: emptyParams)
                if SQLEval.truth(try SQLEval.evaluate(whenExpr, env)) != .yes { continue }
            }
            for statement in trigger.body {
                // Each body statement runs through the ordinary write path; its
                // VALUES/SET/WHERE see NEW/OLD via the frame on `ctx`. A fresh WriteTxn
                // is just a handle over the same `ctx` (the SQLTransaction pattern).
                let txn = WriteTxn(ctx: ctx)
                // Re-establish the frame: a nested fired trigger may have changed it.
                ctx.triggerFrame = frame
                _ = try Writer.execute(statement, txn: txn, params: emptyParams)
            }
        }
    }

    func triggerNames(
        targeting table: String, in ctx: TxnContext
    ) throws(DBError) -> [String] {
        let state = try Relation.ensureState(ctx)
        var names: [String] = []
        for name in state.triggerTexts.keys.sorted() {
            let def = try Self.parsed(ctx, name: name, sql: state.triggerTexts[name]!)
            if def.table == table { names.append(name) }
        }
        return names
    }

    // MARK: - Parse + per-transaction cache

    /// Re-parses a stored CREATE TRIGGER text into a `TriggerDefinition`,
    /// verifying the name matches its catalog key.
    static func parse(
        _ text: String, expectedName: String
    ) throws(DBError) -> TriggerDefinition {
        guard case .createTrigger(let create) = try SQLParser.parseOne(text) else {
            throw DBError.integrityFailure("catalog: trigger \(expectedName) text is not CREATE TRIGGER")
        }
        guard create.definition.name == expectedName else {
            throw DBError.integrityFailure(
                "catalog: trigger name \(create.definition.name) ≠ key \(expectedName)")
        }
        return create.definition
    }

    /// The triggers on `table` for `event`, name-sorted (SQLite fires same-event
    /// triggers in name order), parsed through the per-transaction cache.
    private static func matching(
        _ ctx: TxnContext, state: RelationState, table: String, event: TriggerEvent
    ) throws(DBError) -> [TriggerDefinition] {
        var result: [TriggerDefinition] = []
        for name in state.triggerTexts.keys.sorted() {
            let def = try parsed(ctx, name: name, sql: state.triggerTexts[name]!)
            if def.table == table && def.event == event { result.append(def) }
        }
        return result
    }

    private static func parsed(
        _ ctx: TxnContext, name: String, sql: String
    ) throws(DBError) -> TriggerDefinition {
        let cache =
            ctx.triggerCache as? TriggerParseCache
            ?? {
                let fresh = TriggerParseCache()
                ctx.triggerCache = fresh
                return fresh
            }()
        if let def = cache.byName[name] { return def }
        let def = try parse(sql, expectedName: name)
        cache.byName[name] = def
        return def
    }

    // MARK: - NEW/OLD resolution (used by the Writer's row env)

    /// The evaluation environment for trigger-body expressions: `new.col`/`old.col`
    /// resolve from the active frame, everything else (parameters — empty here)
    /// behaves like a parameters-only env. Used for `WHEN` and as the base the
    /// write path layers row access onto via `triggerColumn`.
    static func bodyEnv(_ ctx: TxnContext, params: SQLParameters) -> SQLEvalEnv {
        SQLEvalEnv(
            parameter: { p throws(DBError) in try params.lookup(p) },
            column: { (qualifier, name, offset) throws(DBError) in
                guard let value = try triggerColumn(ctx, qualifier: qualifier, name: name, offset: offset)
                else {
                    throw DBError.sqlBind(
                        "column \(qualifier.map { "\($0)." } ?? "")\(name) is not available in a trigger body")
                }
                return value
            },
            collationOf: { (qualifier, name) in triggerCollation(ctx, qualifier: qualifier, name: name) },
            columnTypeOf: { (qualifier, name) in triggerColumnType(ctx, qualifier: qualifier, name: name) },
            scalarSubquery: { _ throws(DBError) in
                throw DBError.sqlUnsupported("subquery in a trigger body")
            })
    }

    /// Resolves `new.col`/`old.col` from the active trigger frame, or nil when the
    /// qualifier is not NEW/OLD (so a caller can fall back to its own resolver).
    /// Throws when NEW/OLD is referenced but absent for this event, or the column
    /// name is unknown — matching SQLite ("no such column: new.x").
    static func triggerColumn(
        _ ctx: TxnContext, qualifier: String?, name: String, offset: Int
    ) throws(DBError) -> Value? {
        guard let qualifier, let frame = ctx.triggerFrame else { return nil }
        let lowered = qualifier.lowercased()
        let row: [Value]?
        switch lowered {
        case "new": row = frame.new
        case "old": row = frame.old
        default: return nil
        }
        guard let row else {
            throw DBError.sqlBind("\(lowered) is not available in this trigger event")
        }
        guard let index = frame.table.columnIndex(of: name) else {
            // `new.rowid`/`old.rowid` alias the integer primary key (or rowid).
            if name.lowercased() == "rowid", let aliasIndex = frame.table.rowidAliasIndex {
                return row[aliasIndex]
            }
            throw DBError.noSuchColumn(table: lowered, column: name)
        }
        return row[index]
    }

    static func triggerCollation(
        _ ctx: TxnContext, qualifier: String?, name: String
    ) -> Collation? {
        guard let qualifier, let frame = ctx.triggerFrame,
            qualifier.lowercased() == "new" || qualifier.lowercased() == "old"
        else { return nil }
        return frame.table.columnIndex(of: name).map { frame.table.columns[$0].collation }
    }

    static func triggerColumnType(
        _ ctx: TxnContext, qualifier: String?, name: String
    ) -> ColumnType? {
        guard let qualifier, let frame = ctx.triggerFrame,
            qualifier.lowercased() == "new" || qualifier.lowercased() == "old"
        else { return nil }
        return frame.table.columnIndex(of: name).map { frame.table.columns[$0].type }
    }
}

/// Per-write-transaction cache of parsed trigger definitions, keyed by name.
/// Lives on `TxnContext.triggerCache` (writer-thread-confined, so no lock), and
/// dies with the transaction — matching the old `RelationState.triggerRecords`
/// lifetime. A parsed definition is a pure function of its immutable stored text,
/// so a rolled-back request scope leaves cached entries harmlessly valid.
final class TriggerParseCache {
    var byName: [String: TriggerDefinition] = [:]
}

extension Schema {
    /// Re-derives the parsed trigger definitions from the stored CREATE TRIGGER
    /// texts. The catalog persists only text (like SQLite's `sqlite_schema`); the
    /// SQL layer parses on demand. Throws if a stored text fails to parse.
    package func triggers() throws(DBError) -> [String: TriggerDefinition] {
        var out: [String: TriggerDefinition] = [:]
        out.reserveCapacity(triggerTexts.count)
        for (name, sql) in triggerTexts {
            out[name] = try SQLTriggerEngine.parse(sql, expectedName: name)
        }
        return out
    }
}
