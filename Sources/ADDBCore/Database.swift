public import ADFIO
import Dispatch
public import Synchronization

/// Options controlling how a ``Database`` is opened and run: durability profile,
/// reserved mapping size, read-only / create-if-missing access, forward-scan
/// readahead, and execution-strategy selection.
public struct DatabaseOptions: Sendable {
    public var durability: DurabilityProfile
    /// Reserved virtual address space; the file may grow up to this size.
    public var maxMapSize: Int
    public var readOnly: Bool
    public var createIfMissing: Bool
    /// Readahead a forward scan keeps in flight ahead of its cursor, in bytes
    /// (rounded down to whole 16 KiB pages; 0 disables). The mapping stays
    /// `MADV_RANDOM` for point gets — this only issues additive `MADV_WILLNEED`
    /// prefetch as a cursor iterates, so a cold full scan isn't bottlenecked on a
    /// synchronous fault per leaf. The window is resident per active scan cursor;
    /// the 16 MiB default suits memory-comfortable deployments. Lower it on tight
    /// hosts; raise it for scan-heavy workloads on fast storage.
    public var scanReadaheadBytes: Int
    /// Selects/tunes the execution strategies (evaluator, join, insert). Defaults
    /// to the reference behavior; alternatives are opt-in and benchmarked before
    /// becoming a default. Per-statement overrides via `Statement.setExecutionOptions`.
    public var execution: ExecutionOptions
    /// When true, every committed page is checksum-verified as it is faulted in
    /// on the read path — continuous corruption detection for untrusted database
    /// files, at the cost of an XXH64 over each page touched. Off by default: the
    /// format is crash-safe by construction and reads are the hot path;
    /// `verifyIntegrity` remains the on-demand whole-file check.
    public var verifyChecksumsOnRead: Bool

    public init(
        durability: DurabilityProfile = .barrier,
        maxMapSize: Int = 64 << 30,
        readOnly: Bool = false,
        createIfMissing: Bool = true,
        scanReadaheadBytes: Int = 16 << 20,
        execution: ExecutionOptions = .default,
        verifyChecksumsOnRead: Bool = false
    ) {
        self.durability = durability
        self.maxMapSize = maxMapSize
        self.readOnly = readOnly
        self.createIfMissing = createIfMissing
        self.scanReadaheadBytes = scanReadaheadBytes
        self.execution = execution
        self.verifyChecksumsOnRead = verifyChecksumsOnRead
    }
}

/// Marker for the SQL layer's parsed-statement store, held opaquely on the
/// database so storage never names the SQL cache type. The store is `Sendable`
/// (self-synchronized); storage only guards its one-time creation.
@_spi(ADDBEngine) public protocol SQLStatementStore: AnyObject, Sendable {}

/// An ADSQL database handle.
///
/// Concurrency model: any number of concurrent readers (snapshot isolation,
/// no locks held while reading pages) and one writer at a time. Reader
/// registration and meta publication share one critical section, so the
/// writer's page-reclamation horizon can never race past a reader that is
/// still acquiring its snapshot.
public final class Database: Sendable {
    struct Shared {
        var meta: Meta
        var closed = false
        /// generation → active read transaction count.
        var readers: [UInt64: Int] = [:]
        /// Last minimum published to the cross-process slot (0 = none).
        var publishedMin: UInt64 = 0
        /// The full-text-search query evaluator (nil until `enableFullTextSearch()`).
        /// Kept here, rather than in a separate box, so every read/write transaction
        /// reads it inside the snapshot lock it already takes — zero extra locking on
        /// the hot path whether or not FTS is enabled.
        var ftsEvaluator: (any FTSEvaluation)?
    }

    public let path: String
    let channel: FileChannel
    let pager: Pager
    @_spi(ADDBEngine) public let options: DatabaseOptions
    let readerTable: ReaderTable
    let shared: Mutex<Shared>
    /// Writer exclusion: one dedicated large-stack serial thread shared by
    /// `writeSync` and the group-commit drain. Same serial/FIFO contract the
    /// `adsql.writer` queue had, but its big stack lets recursive trigger
    /// chains nest far deeper without overflowing (see `WriterThread`).
    let writerThread: WriterThread
    /// Queued group-commit requests awaiting the next drain.
    let pendingWrites = Mutex<[PendingWrite]>([])
    /// Latest-known schema snapshot, keyed by catalog version (MVCC-correct:
    /// readers verify their snapshot's version row before reuse).
    let relationSchemaCache = SchemaCache()
    /// The SQL layer's parsed-statement cache (keyed by SQL text; the
    /// schema-independent half of `prepare`), lazily created and held behind the
    /// `SQLStatementStore` marker so storage never names the SQL cache type. Bound
    /// plans live on each `Statement`, keyed by catalog version.
    @_spi(ADDBEngine) public let sqlStatementStoreBox = Mutex<(any SQLStatementStore)?>(nil)

    /// Returns the SQL statement store, creating it once via `make` under the
    /// box's lock. The store is `Sendable` (self-synchronized), so callers use it
    /// outside the lock.
    @_spi(ADDBEngine) public func sqlStatementStore(
        orCreate make: () -> any SQLStatementStore
    ) -> any SQLStatementStore {
        sqlStatementStoreBox.withLock { box in
            if let existing = box { return existing }
            let created = make()
            box = created
            return created
        }
    }
    /// The SQL-layer trigger engine, installed lazily by the SQL layer on first
    /// `prepare`/`transaction`. Held behind the storage-defined `TriggerFiring`
    /// protocol so this layer never references the SQL engine type. Copied onto
    /// every write context, so all write paths fire triggers uniformly.
    let triggerEngineBox = Mutex<(any TriggerFiring)?>(nil)

    /// Installs the trigger engine (idempotent, one-way): the SQL layer calls this
    /// before running any SQL, so a write context created afterward can fire
    /// triggers. Stays nil for raw key/value databases that never touch SQL.
    @_spi(ADDBEngine) public func installTriggerEngine(_ engine: any TriggerFiring) {
        triggerEngineBox.withLock { if $0 == nil { $0 = engine } }
    }

    /// Installs the FTS query evaluator (idempotent, one-way), held behind the
    /// storage-defined `FTSEvaluation` protocol so this layer never references a
    /// query-language type. Unlike the trigger engine — which the SQL layer
    /// self-installs on `prepare` — the evaluator lives *above* the SQL engine, so
    /// the `ADSQLFullTextSearch` module installs it explicitly
    /// (`Database.enableFullTextSearch()`). Copied onto each read/write transaction
    /// so MATCH resolves uniformly; stays nil until enabled — a MATCH row source
    /// then throws a clear error instead.
    @_spi(ADDBEngine) public func installFTSEvaluator(_ evaluator: any FTSEvaluation) {
        shared.withLock { if $0.ftsEvaluator == nil { $0.ftsEvaluator = evaluator } }
    }

    private init(
        path: String, channel: FileChannel, pager: Pager, options: DatabaseOptions,
        readerTable: ReaderTable, meta: Meta
    ) {
        self.path = path
        self.channel = channel
        self.pager = pager
        self.options = options
        self.readerTable = readerTable
        self.shared = Mutex(Shared(meta: meta))
        // An idle writer thread costs a control block plus ~1 lazily-committed
        // stack page; the big reservation is virtual until trigger recursion uses
        // it. Created here so every handle owns its serial writer for its lifetime.
        self.writerThread = WriterThread()
    }

    /// Stops the writer thread. No retain cycle prevents this from running: the
    /// pthread start-arg references `WriterThread` (via `Unmanaged`), not
    /// `Database`. A group-commit drain job DOES capture `Database` (`[self]`), so
    /// the worker can drop the last reference when it frees that closure — meaning
    /// `deinit` (and this `shutdown`) may run on the writer thread itself.
    /// `WriterThread.shutdown` handles that case by detaching instead of
    /// self-joining; off the writer thread it joins synchronously.
    deinit {
        writerThread.shutdown()
    }

    public static func open(
        at path: String, options: DatabaseOptions = DatabaseOptions()
    ) throws(DBError) -> Database {
        let channel = try FileChannel(
            path: path,
            mode: options.readOnly ? .readOnly : .readWrite(create: options.createIfMissing))
        let meta: Meta
        do {
            meta = try Recovery.openOrCreate(
                channel: channel, createIfMissing: options.createIfMissing && !options.readOnly)
        } catch {
            channel.close()
            throw error
        }
        guard Int(meta.pageCount) * Format.pageSize <= options.maxMapSize else {
            channel.close()
            throw DBError.mapFull
        }
        let pager: Pager
        do {
            pager = try Pager(
                channel: channel, maxMapSize: options.maxMapSize,
                readaheadBytes: options.scanReadaheadBytes)
        } catch {
            channel.close()
            throw error
        }
        // Cross-process coordination: reader slot for every handle, the fcntl
        // writer lock for read-write handles.
        let readerTable: ReaderTable
        do {
            readerTable = try ReaderTable(databasePath: path, claimWriterLock: !options.readOnly)
        } catch {
            channel.close()
            throw error
        }
        return Database(
            path: path, channel: channel, pager: pager, options: options,
            readerTable: readerTable, meta: meta)
    }

    /// Marks the handle closed; new transactions fail. The mapping and file
    /// descriptor are released when the last reference goes away.
    public func close() {
        shared.withLock { $0.closed = true }
    }

    /// Generation of the most recent commit.
    public var generation: UInt64 {
        shared.withLock { $0.meta.generation }
    }

    /// Number of key-value pairs at the most recent commit.
    public var count: UInt64 {
        shared.withLock { $0.meta.kvCount }
    }

    @inline(__always)
    static func checkUserKey(_ key: [UInt8]) throws(DBError) {
        if key.first == Format.reservedKeyPrefix { throw DBError.reservedKey }
    }

    // MARK: - Reads

    /// Runs `body` against an immutable snapshot of the newest committed
    /// generation. Readers never block the writer and vice versa.
    public func read<R>(
        _ body: (borrowing ReadTxn) throws(DBError) -> R
    ) throws(DBError) -> R {
        try withReaderSignpost("read") { () throws(DBError) in
            let (meta, fts) = try beginRead()
            defer { endRead(generation: meta.generation) }
            let txn = ReadTxn(
                resolver: CommittedResolver(
                    source: pager, pageCount: meta.pageCount,
                    verifyChecksums: options.verifyChecksumsOnRead, ftsEvaluator: fts),
                meta: meta, schemaCache: relationSchemaCache)
            return try body(txn)
        }
    }

    /// Registers a reader and returns its snapshot meta plus the installed FTS
    /// evaluator (read in the same critical section, so the read path takes no
    /// extra lock for it). The evaluator is nil unless `enableFullTextSearch()` ran.
    func beginRead() throws(DBError) -> (meta: Meta, fts: (any FTSEvaluation)?) {
        // Read-only handles have no writer in-process: refresh the committed
        // meta from the mapped meta pages (checksums make torn reads safe).
        let refreshed: Meta? =
            if options.readOnly {
                unsafe try? Meta.recover(meta0: pager.map.pageBytes(0), meta1: pager.map.pageBytes(1))
            } else {
                nil
            }
        let snapshot: (Meta, (any FTSEvaluation)?)? = shared.withLock { state in
            guard !state.closed else { return nil }
            if let refreshed, refreshed.generation > state.meta.generation {
                state.meta = refreshed
            }
            state.readers[state.meta.generation, default: 0] += 1
            publishMinLocked(&state)
            return (state.meta, state.ftsEvaluator)
        }
        guard let snapshot else { throw DBError.databaseClosed }
        return snapshot
    }

    func endRead(generation: UInt64) {
        shared.withLock { state in
            if let count = state.readers[generation] {
                if count <= 1 {
                    state.readers.removeValue(forKey: generation)
                } else {
                    state.readers[generation] = count - 1
                }
            }
            publishMinLocked(&state)
        }
    }

    /// Mirrors the in-process minimum reader generation into this handle's
    /// cross-process slot. Called with the state lock held, so slot order is
    /// consistent with meta publication.
    private func publishMinLocked(_ state: inout Shared) {
        let minimum = state.readers.keys.min() ?? 0
        if minimum != state.publishedMin {
            readerTable.publish(minGeneration: minimum)
            state.publishedMin = minimum
        }
    }

    // MARK: - Writes

    /// Runs one exclusive write transaction synchronously. On a thrown error
    /// nothing is persisted; on return the transaction is durably committed
    /// per the database's durability profile.
    @discardableResult
    public func writeSync<R>(
        _ body: (borrowing WriteTxn) throws(DBError) -> R
    ) throws(DBError) -> R {
        guard !options.readOnly else { throw DBError.readOnlyDatabase }
        var result: Result<R, DBError>?
        writerThread.sync {
            do throws(DBError) {
                result = .success(
                    try withWriterSignpost("write") { () throws(DBError) in try performWrite(body) })
            } catch {
                result = .failure(error)
            }
        }
        return try result!.get()
    }

    private func performWrite<R>(
        _ body: (borrowing WriteTxn) throws(DBError) -> R
    ) throws(DBError) -> R {
        readerTable.sweepStaleSlots()
        let foreignMin = readerTable.minimumGeneration() ?? UInt64.max
        let snapshot: (Meta, UInt64, (any FTSEvaluation)?)? = shared.withLock { state in
            guard !state.closed else { return nil }
            let localMin = state.readers.keys.min() ?? UInt64.max
            return (
                state.meta, state.meta.reclaimLimit(minReader: min(localMin, foreignMin)),
                state.ftsEvaluator
            )
        }
        guard let (meta, reclaimLimit, fts) = snapshot else { throw DBError.databaseClosed }

        let ctx = TxnContext(source: pager, meta: meta)
        ctx.appendCursorEnabled = options.execution.insert == .appendCursor
        ctx.insertHoistEnabled = options.execution.insert == .hoisted
        ctx.triggerEngine = triggerEngineBox.withLock { $0 }
        ctx.ftsEvaluator = fts
        try FreeList.harvest(ctx: ctx, upTo: reclaimLimit)
        let baselineMain = ctx.meta.mainTree

        let txn = WriteTxn(ctx: ctx)
        let result = try body(txn)
        if ctx.relation != nil {
            try Relation.serializeState(ctx: ctx)
        }

        // Nothing user-visible changed: drop the transaction entirely (harvest
        // churn was memory-only).
        if ctx.meta.mainTree == baselineMain && ctx.pendingFree.isEmpty && ctx.dirty.isEmpty {
            return result
        }

        try FreeList.serialize(ctx: ctx)
        guard Int(ctx.allocator.highWater) * Format.pageSize <= options.maxMapSize else {
            throw DBError.mapFull
        }
        let newMeta = try Committer.commit(
            ctx: ctx, channel: channel, durability: options.durability)
        shared.withLock { $0.meta = newMeta }
        if let state = ctx.relation { relationSchemaCache.publish(state.schema) }
        return result
    }
}

// MARK: - Transactions

/// A read snapshot. Noncopyable and only ever borrowed by the `read` closure,
/// so it cannot outlive its reader registration.
public struct ReadTxn: ~Copyable {
    @_spi(ADDBEngine) public let resolver: CommittedResolver
    @_spi(ADDBEngine) public let meta: Meta
    @_spi(ADDBEngine) public let schemaCache: SchemaCache?

    public var generation: UInt64 { meta.generation }
    public var count: UInt64 { meta.kvCount }

    /// Copying point lookup.
    public func get(_ key: [UInt8]) throws(DBError) -> [UInt8]? {
        try Database.checkUserKey(key)
        var result: Result<[UInt8]?, DBError> = .success(nil)
        key.withUnsafeBytes { keyBytes in
            do throws(DBError) {
                guard let ref = unsafe try BTree.get(resolver: resolver, meta: meta, key: keyBytes) else {
                    return
                }
                result = .success(try BTree.copyValue(ref, resolver: resolver))
            } catch {
                result = .failure(error)
            }
        }
        return try result.get()
    }

    /// True when `key` is present in this snapshot.
    public func contains(_ key: [UInt8]) throws(DBError) -> Bool {
        try Database.checkUserKey(key)
        var result: Result<Bool, DBError> = .success(false)
        key.withUnsafeBytes { keyBytes in
            do throws(DBError) {
                result = unsafe .success(try BTree.get(resolver: resolver, meta: meta, key: keyBytes) != nil)
            } catch {
                result = .failure(error)
            }
        }
        return try result.get()
    }

    /// Zero-copy scoped access: inline values are handed out as a `RawSpan`
    /// over the mapped page (bounds-checked, non-escapable); overflow values
    /// are materialized once and spanned. `body` receives nil when the key is
    /// absent.
    public func withValue<R>(
        forKey key: [UInt8], _ body: (RawSpan?) throws(DBError) -> R
    ) throws(DBError) -> R {
        try Database.checkUserKey(key)
        var result: Result<R, DBError>?
        key.withUnsafeBytes { keyBytes in
            do throws(DBError) {
                guard let ref = unsafe try BTree.get(resolver: resolver, meta: meta, key: keyBytes) else {
                    result = .success(try body(nil))
                    return
                }
                switch ref {
                case .inline(let bytes):
                    // `bytes` is already a RawSpan bound to the resolver (BTree.get), so
                    // it hands straight to the body — valid for this scope.
                    result = .success(try body(bytes))
                case .overflow:
                    let copied = try BTree.copyValue(ref, resolver: resolver)
                    var inner: Result<R, DBError>?
                    copied.withUnsafeBytes { raw in
                        do throws(DBError) {
                            // raw is owned by `copied`, alive for this withUnsafeBytes scope.
                            inner = unsafe .success(
                                try Self.withRawSpan(over: raw) { (span: RawSpan) throws(DBError) in try body(span) })
                        } catch {
                            inner = .failure(error)
                        }
                    }
                    result = inner
                }
            } catch {
                result = .failure(error)
            }
        }
        return try result!.get()
    }

    /// The single bridge from raw bytes to the safe `RawSpan` type. The
    /// underscored `_unsafeBytes:` SPI asserts (does not check) the span's
    /// lifetime and is unstable across compilers, so it is confined here to one
    /// call site; both callers keep `bytes` alive for the closure's duration
    ///
    private static func withRawSpan<R, E: Error>(
        over bytes: UnsafeRawBufferPointer, _ body: (RawSpan) throws(E) -> R
    ) throws(E) -> R {
        try body(unsafe RawSpan(_unsafeBytes: bytes))
    }

    /// Scoped ordered iteration over the snapshot. Low-level (yields a `Cursor`
    /// over the storage layer); `package` — in-package consumers (tests, bench)
    /// reach it via `import ADDB`.
    @_spi(ADDBEngine) public func withCursor<R>(
        _ body: (inout Cursor<CommittedResolver>) throws(DBError) -> R
    ) throws(DBError) -> R {
        var cursor = Cursor(resolver: resolver, meta: meta)
        return try body(&cursor)
    }

    /// Visits every user (key, value) pair in order (system rows under the
    /// reserved 0x00 prefix are skipped). Values are materialized.
    public func forEach(
        _ body: ([UInt8], [UInt8]) throws(DBError) -> Void
    ) throws(DBError) {
        unsafe try BTree.forEach(resolver: resolver, meta: meta) { (key, ref) throws(DBError) in
            if unsafe key.first == Format.reservedKeyPrefix { return }
            unsafe try body([UInt8](key), try BTree.copyValue(ref, resolver: resolver))
        }
    }
}

/// An exclusive write transaction. Mutations become visible atomically at
/// commit (when the `writeSync` closure returns without throwing).
public struct WriteTxn: ~Copyable {
    @_spi(ADDBEngine) public let ctx: TxnContext

    @_spi(ADDBEngine) public init(ctx: TxnContext) { self.ctx = ctx }

    /// Inserts or replaces.
    public func put(_ key: [UInt8], _ value: [UInt8]) throws(DBError) {
        try Database.checkUserKey(key)
        try key.withUnsafeBytesThrowing { keyBytes throws(DBError) in
            try value.withUnsafeBytesThrowing { valueBytes throws(DBError) in
                unsafe try BTree.put(ctx: ctx, key: keyBytes, value: valueBytes)
            }
        }
    }

    /// Returns true when the key existed.
    @discardableResult
    public func delete(_ key: [UInt8]) throws(DBError) -> Bool {
        try Database.checkUserKey(key)
        var result: Result<Bool, DBError> = .success(false)
        key.withUnsafeBytes { keyBytes in
            do throws(DBError) {
                result = unsafe .success(try BTree.delete(ctx: ctx, key: keyBytes))
            } catch {
                result = .failure(error)
            }
        }
        return try result.get()
    }

    /// Reads through this transaction's own uncommitted writes.
    public func get(_ key: [UInt8]) throws(DBError) -> [UInt8]? {
        try Database.checkUserKey(key)
        var result: Result<[UInt8]?, DBError> = .success(nil)
        key.withUnsafeBytes { keyBytes in
            do throws(DBError) {
                guard let ref = unsafe try BTree.get(resolver: ctx, meta: ctx.meta, key: keyBytes) else {
                    return
                }
                result = .success(try BTree.copyValue(ref, resolver: ctx))
            } catch {
                result = .failure(error)
            }
        }
        return try result.get()
    }

    public var count: UInt64 { ctx.meta.kvCount }
}
