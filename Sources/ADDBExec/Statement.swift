@_spi(ADDBEngine) import ADDBCore
public import ADSQL
public import ADSQLModel
import Synchronization

/// Bound parameter values for one execution. Positional `?` markers are
/// 1-based by appearance order; `$name`/`:name` markers resolve by name
/// (without the sigil).
public struct SQLParameters: Sendable {
    public var positional: [Value]
    public var named: [String: Value]
    /// The clock `datetime('now')` resolves against (epoch seconds). Threaded from
    /// `Database.options.now` by the statement layer at execution; the public init
    /// keeps the live-clock default, so callers building parameters never see it.
    var now: @Sendable () -> Int64 = CivilTime.liveEpochSeconds

    public init(positional: [Value] = [], named: [String: Value] = [:]) {
        self.positional = positional
        self.named = named
    }

    func lookup(_ parameter: SQLParam) throws(DBError) -> Value {
        switch parameter {
            case .positional(let index):
                guard index >= 1, index <= positional.count else {
                    throw DBError.sqlBind("missing positional parameter ?\(index)")
                }
                return positional[index - 1]
            case .named(let name):
                guard let value = named[name] else {
                    throw DBError.sqlBind("missing parameter for :\(name)/$\(name)")
                }
                return value
        }
    }
}

/// The outcome of a non-query execution.
public struct RunResult: Sendable {
    /// The number of rows inserted, updated, or deleted by the statement.
    public let changes: Int
    /// The rowid of the most recent row inserted by the statement (0 if none).
    public let lastInsertRowid: Int64

    public init(changes: Int = 0, lastInsertRowid: Int64 = 0) {
        self.changes = changes
        self.lastInsertRowid = lastInsertRowid
    }
}

/// A parsed, reusable statement. `prepare` only lexes and parses (no schema);
/// each execution binds against the transaction's schema and reuses the bound
/// plan while the catalog version is unchanged. Safe to share across tasks:
/// every execution opens its own transaction and uses its own row state, and
/// the bound-plan cache is mutex-guarded.
public final class Statement: Sendable {
    private unowned let database: Database
    public let sql: String
    let ast: SQLStatementAST
    public let isReadOnly: Bool

    private struct CachedPlan: Sendable {
        let catalogVersion: UInt64
        /// Planning-relevant execution options (join strategy) the plan was bound
        /// under; a change invalidates the cached plan.
        let planningTag: Int
        let query: BoundQuery
    }
    private let cachedPlan = Mutex<CachedPlan?>(nil)
    /// Per-statement execution-option override (nil = use the database default).
    private let executionOverride = Mutex<ExecutionOptions?>(nil)

    /// A completed execution that reached the slow-query threshold — handed to the hook.
    public struct SlowQuery: Sendable {
        public let sql: String
        public let elapsed: Duration
    }
    /// Optional slow-query observer: the hook fires after an execution whose wall-clock duration
    /// reaches the threshold. nil = no timing (zero overhead on the hot path).
    private let slowQuery = Mutex<(threshold: Duration, hook: @Sendable (SlowQuery) -> Void)?>(nil)

    init(database: Database, sql: String, parsed: ParsedStatement) {
        self.database = database
        self.sql = sql
        self.ast = parsed.ast
        self.isReadOnly = parsed.isReadOnly
    }

    /// Overrides the execution strategies for this statement (nil reverts to the
    /// database default). Thread-safe; takes effect on the next execution.
    public func setExecutionOptions(_ options: ExecutionOptions?) {
        executionOverride.withLock { $0 = options }
    }

    /// The strategies in effect: the per-statement override, else the database default.
    var effectiveExecution: ExecutionOptions {
        executionOverride.withLock { $0 } ?? database.options.execution
    }

    /// Observe executions of this statement that take at least `threshold`: the hook fires with the SQL
    /// text + measured duration after `all`/`get`/`run` (the streaming `forEach` is exempt). Thread-safe;
    /// set once on a prepared (and cached) statement. Pass a near-zero threshold to observe every run.
    public func setSlowQueryHook(
        threshold: Duration, _ hook: @escaping @Sendable (SlowQuery) -> Void
    ) {
        slowQuery.withLock { $0 = (threshold, hook) }
    }
    /// Removes a previously installed slow-query hook.
    public func clearSlowQueryHook() {
        slowQuery.withLock { $0 = nil }
    }

    // MARK: - Execution

    /// All result rows (a SELECT result set, or a write's RETURNING rows).
    public func all(_ parameters: Value...) throws(DBError) -> [SQLRow] {
        try all(SQLParameters(positional: parameters))
    }
    public func all(_ named: [String: Value]) throws(DBError) -> [SQLRow] {
        try all(SQLParameters(named: named))
    }
    public func all(_ parameters: SQLParameters) throws(DBError) -> [SQLRow] {
        try execute(parameters).rows
    }

    /// The first result row, or nil.
    public func get(_ parameters: Value...) throws(DBError) -> SQLRow? {
        try execute(SQLParameters(positional: parameters)).rows.first
    }
    public func get(_ named: [String: Value]) throws(DBError) -> SQLRow? {
        try execute(SQLParameters(named: named)).rows.first
    }
    public func get(_ parameters: SQLParameters) throws(DBError) -> SQLRow? {
        try execute(parameters).rows.first
    }

    /// Streams result rows to `body` one at a time, returning `false` from `body`
    /// to stop early — SQLite's `sqlite3_step` row-at-a-time model. The **unbounded
    /// single-table** read path (no ORDER BY sort, no LIMIT/OFFSET, no GROUP BY /
    /// aggregate / join) never materializes the full result set: memory stays
    /// bounded to one row (plus, for DISTINCT, the seen-key set), and an early
    /// `false` stops the scan immediately rather than after building every row.
    /// Sorted / grouped / joined / limited queries (already memory-bounded, or
    /// needing the full set to sort) are materialized internally, then their
    /// finished rows are streamed to `body`. `body` runs inside the read snapshot;
    /// each `SQLRow` owns its `Value`s, so copying values out is safe.
    public func forEach(
        _ parameters: SQLParameters = SQLParameters(),
        _ body: @escaping (SQLRow) throws(DBError) -> Bool
    ) throws(DBError) {
        guard case .select(let select) = ast else {
            throw DBError.sqlUnsupported("statement does not return rows")
        }
        let execution = effectiveExecution
        try database.read { (txn) throws(DBError) in
            switch try self.boundQuery(
                select, schema: try txn.schema(), planningTag: execution.planningTag)
            {
                case .select(let plan):
                    let header = plan.header
                    // A streamable single-table plan emits each row through `sink` and
                    // returns []; any other plan ignores `sink` and returns its materialized
                    // rows, which we stream to `body` here. Either way `body` is invoked
                    // exactly once per result row, in order.
                    let materialized = try Self.runSelect(
                        plan, txn: txn, params: parameters, execution: execution,
                        sink: { (values) throws(DBError) -> Bool in
                            try body(SQLRow(header: header, values: values))
                        })
                    for row in materialized where try !body(row) {
                        return
                    }
                case .compound(let compound):
                    let rows = try Self.runCompound(
                        compound, txn: txn, params: parameters, execution: execution)
                    for row in rows where try !body(row) {
                        return
                    }
            }
        }
    }

    /// `forEach` with positional parameters.
    public func forEach(
        _ parameters: [Value], _ body: @escaping (SQLRow) throws(DBError) -> Bool
    ) throws(DBError) {
        try forEach(SQLParameters(positional: parameters), body)
    }

    /// Executes for effect; any rows (e.g. RETURNING) are discarded.
    @discardableResult
    public func run(_ parameters: Value...) throws(DBError) -> RunResult {
        try run(SQLParameters(positional: parameters))
    }
    @discardableResult
    public func run(_ named: [String: Value]) throws(DBError) -> RunResult {
        try run(SQLParameters(named: named))
    }
    @discardableResult
    public func run(_ parameters: SQLParameters) throws(DBError) -> RunResult {
        try execute(parameters).result
    }

    // MARK: - Internals

    /// Routes by statement kind: SELECT/compound reads run in a read snapshot;
    /// INSERT/UPDATE/DELETE/DDL run in one exclusive write transaction.
    private func execute(
        _ parameters: SQLParameters
    ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
        guard let observer = slowQuery.withLock({ $0 }) else {
            return try executeInner(parameters)
        }
        // Time the execution on a monotonic clock (paid only when a hook is installed); the hook fires
        // in a `defer`, so a slow query that ultimately throws is still observed.
        let clock = ContinuousClock()
        let start = clock.now
        defer {
            let elapsed = clock.now - start
            if elapsed >= observer.threshold {
                observer.hook(SlowQuery(sql: sql, elapsed: elapsed))
            }
        }
        return try executeInner(parameters)
    }

    private func executeInner(
        _ parameters: SQLParameters
    ) throws(DBError) -> (rows: [SQLRow], result: RunResult) {
        // Thread the database's configured clock (live by default) onto the parameters
        // so every eval env resolves `datetime('now')` against it.
        var parameters = parameters
        parameters.now = database.options.now
        switch ast {
            case .select:
                return (try query(parameters), RunResult())
            case .pragma(let name, let value):
                return (Pragma.run(name: name, value: value), RunResult())
            case .insert, .update, .delete, .createTable, .createVirtualTable, .createIndex, .createTrigger,
                .dropTable, .dropIndex, .dropTrigger:
                return try database.writeSync { txn throws(DBError) in
                    try Writer.execute(self.ast, txn: txn, params: parameters)
                }
            case .begin, .commit, .rollback:
                throw DBError.sqlUnsupported("transaction control belongs to db.transaction/execute")
        }
    }

    private func query(_ parameters: SQLParameters) throws(DBError) -> [SQLRow] {
        guard case .select(let select) = ast else {
            throw DBError.sqlUnsupported("statement does not return rows")
        }
        let execution = effectiveExecution
        return try database.read { txn throws(DBError) in
            switch try self.boundQuery(
                select, schema: try txn.schema(), planningTag: execution.planningTag)
            {
                case .select(let plan):
                    return try Self.runSelect(plan, txn: txn, params: parameters, execution: execution)
                case .compound(let compound):
                    return try Self.runCompound(compound, txn: txn, params: parameters, execution: execution)
            }
        }
    }

    /// The chosen access path, SQLite-EXPLAIN-shaped (for planner assertions).
    public func planDescription() throws(DBError) -> String {
        guard case .select(let select) = ast else {
            throw DBError.sqlUnsupported("statement does not return rows")
        }
        return try database.read { txn throws(DBError) in
            switch try self.boundQuery(
                select, schema: try txn.schema(), planningTag: self.effectiveExecution.planningTag)
            {
                case .select(let plan):
                    return plan.access.describe(table: plan.source.table)
                case .compound(let compound):
                    return "COMPOUND (\(compound.arms.count) SELECT)"
            }
        }
    }

    /// The query's access plan as ordered EXPLAIN-QUERY-PLAN steps: the leading table's scan/search
    /// first, then each joined table's nested-loop access. SQLite-shaped (`SCAN t` / `SEARCH t USING
    /// INDEX … (…)`), reusing the same descriptions `planDescription()` does. Read-only: it binds the
    /// plan (cache-hot after the first run) but never executes.
    public func explainQueryPlan() throws(DBError) -> [String] {
        guard case .select(let select) = ast else {
            throw DBError.sqlUnsupported("statement does not return rows")
        }
        return try database.read { txn throws(DBError) in
            switch try self.boundQuery(
                select, schema: try txn.schema(), planningTag: self.effectiveExecution.planningTag)
            {
                case .select(let plan):
                    var steps = [plan.access.describe(table: plan.source.table)]
                    for join in plan.joins {
                        steps.append(join.access.describe(table: plan.binding.tables[join.table].table))
                    }
                    return steps
                case .compound(let compound):
                    return ["COMPOUND (\(compound.arms.count) SELECT)"]
            }
        }
    }

    private func boundQuery(
        _ select: SQLSelect, schema: Schema, planningTag: Int
    ) throws(DBError) -> BoundQuery {
        if let cached = cachedPlan.withLock({ $0 }),
            cached.catalogVersion == schema.catalogVersion, cached.planningTag == planningTag
        {
            return cached.query
        }
        let query = try Binder.bindQuery(select, schema: schema)
        cachedPlan.withLock { existing in
            // Refresh on a newer catalog version or a different planning tag.
            if existing == nil || existing!.catalogVersion < schema.catalogVersion
                || existing!.planningTag != planningTag
            {
                existing = CachedPlan(
                    catalogVersion: schema.catalogVersion, planningTag: planningTag, query: query)
            }
        }
        return query
    }
}

// MARK: - Parse cache

/// The lex+parse product cached by SQL text (the schema-independent half of a
/// statement).
struct ParsedStatement: Sendable {
    let ast: SQLStatementAST
    let isReadOnly: Bool
}

/// A small LRU keyed by SQL text. Re-preparing a hot statement skips the lexer
/// and parser entirely. Self-synchronized (its own `Mutex`), so it is `Sendable`
/// and lives behind the storage layer's `SQLStatementStore` marker — the database
/// holds it without naming this SQL-layer type.
final class StatementCache: SQLStatementStore {
    private struct State {
        var entries: [String: ParsedStatement] = [:]
        var order: [String] = []  // oldest first

        mutating func touch(_ sql: String) {
            if let existing = order.firstIndex(of: sql) { order.remove(at: existing) }
            order.append(sql)
        }
    }

    let capacity: Int
    private let state = Mutex(State())

    init(capacity: Int) { self.capacity = capacity }

    func get(_ sql: String) -> ParsedStatement? {
        state.withLock { s in
            guard let parsed = s.entries[sql] else { return nil }
            s.touch(sql)
            return parsed
        }
    }

    func insert(_ sql: String, _ parsed: ParsedStatement) {
        state.withLock { s in
            s.entries[sql] = parsed
            s.touch(sql)
            while s.order.count > capacity {
                let evicted = s.order.removeFirst()
                s.entries[evicted] = nil
            }
        }
    }
}

extension Database {
    /// The SQL parsed-statement cache, created once in the database's store slot.
    /// The cache is self-synchronized, so `body` runs outside the slot's lock.
    func withStatementCache<R>(_ body: (StatementCache) -> R) -> R {
        // The store is always a `StatementCache` (this is the only producer).
        body(sqlStatementStore(orCreate: { StatementCache(capacity: 128) }) as! StatementCache)
    }
}

extension Database {
    /// Parses `sql` (reusing the parse cache) into a reusable `Statement`.
    public func prepare(_ sql: String) throws(DBError) -> Statement {
        installTriggerEngine(SQLTriggerEngine.shared)
        return Statement(database: self, sql: sql, parsed: try parsedStatement(sql))
    }
}
