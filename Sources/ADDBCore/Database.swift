public import ADFIO
public import ADSQLModel
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
    /// The wall clock `datetime('now')` / `CURRENT_TIMESTAMP` defaults resolve against,
    /// as Unix epoch seconds. Defaults to the live clock; a test passes a fixed provider
    /// to pin time deterministically. Structural seam (a `@Sendable () -> Int64`), so the
    /// engine carries no test dependency.
    public var now: @Sendable () -> Int64

    public init(
        durability: DurabilityProfile = .barrier,
        maxMapSize: Int = 64 << 30,
        readOnly: Bool = false,
        createIfMissing: Bool = true,
        scanReadaheadBytes: Int = 16 << 20,
        execution: ExecutionOptions = .default,
        verifyChecksumsOnRead: Bool = false,
        now: @escaping @Sendable () -> Int64 = CivilTime.liveEpochSeconds
    ) {
        self.durability = durability
        self.maxMapSize = maxMapSize
        self.readOnly = readOnly
        self.createIfMissing = createIfMissing
        self.scanReadaheadBytes = scanReadaheadBytes
        self.execution = execution
        self.verifyChecksumsOnRead = verifyChecksumsOnRead
        self.now = now
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
/// registration is *striped* across `readerShardCount` independent stripes, so
/// concurrent `beginRead`/`endRead` contend only within a stripe — never on one
/// global lock — while the writer's page-reclamation horizon is still gated by a
/// correct LOWER BOUND on every live reader's snapshot generation (see
/// `ReaderShard` and `writeReclaimSnapshot`).
public final class Database: Sendable {
    /// One stripe of reader-registration state. The reader table is sharded across
    /// `readerShardCount` of these so concurrent point reads contend only within a
    /// stripe, not on a single global mutex (which was the throughput ceiling under a
    /// read-saturated multi-core workload). Each stripe carries its OWN copy of the
    /// committed `meta` (plus `closed`/`ftsEvaluator`), refreshed by the writer on
    /// every commit, so a reader reads its snapshot meta under the same short stripe
    /// lock it takes to register — there is no separate, globally-contended meta lock,
    /// and the meta a reader sees can never tear.
    ///
    /// Correctness of page reclamation does NOT depend on any single stripe: the
    /// writer scans EVERY stripe (each under its own lock) for the minimum live-reader
    /// generation before harvesting. That per-stripe scan is a valid lower bound
    /// because (a) an old reader (generation < current commit) is stably present in
    /// its stripe's histogram from before the scan began, so the scan sees it; and
    /// (b) a reader registering *during* the scan necessarily holds the current
    /// committed generation (all stripes still carry it — the writer has not committed
    /// yet), which reclamation never touches (`Meta.reclaimLimit` lags one generation).
    struct ReaderShard {
        var meta: Meta
        var closed = false
        /// The full-text-search query evaluator (nil until `enableFullTextSearch()`).
        /// Replicated per stripe so every read transaction reads it under the stripe
        /// lock it already takes — zero extra locking on the hot path.
        var ftsEvaluator: (any FTSEvaluation)?
        /// generation → active read-transaction count for readers assigned to this stripe.
        var readers: [UInt64: Int] = [:]

        /// The oldest generation with a live reader in this stripe (nil = none).
        var minGeneration: UInt64? { readers.keys.min() }
    }

    /// Heap box per stripe: a class gives each `Mutex` its own allocation (distinct
    /// stripes land on distinct cache lines, avoiding false sharing) and lets the
    /// stripes live in a plain `Array` — a `Mutex` is non-copyable, so `[Mutex<…>]`
    /// is not directly expressible.
    final class ShardBox: Sendable {
        let lock: Mutex<ReaderShard>
        init(_ initial: ReaderShard) { self.lock = Mutex(initial) }
    }

    public let path: String
    let channel: FileChannel
    let pager: Pager
    @_spi(ADDBEngine) public let options: DatabaseOptions
    let readerTable: ReaderTable
    /// Reader-registration stripes (see `ReaderShard`). Count is a power of two so the
    /// round-robin selector masks instead of dividing.
    static let readerShardCount = 16
    let shards: [ShardBox]
    /// Round-robin stripe selector for `beginRead` (relaxed: which stripe a reader
    /// lands in never affects correctness — `beginRead` returns the chosen index and
    /// `endRead` decrements the SAME stripe — only load distribution).
    let shardCursor = Atomic<UInt64>(0)
    /// The value last written to this handle's cross-process reader-table slot
    /// (0 = none). Read-only handles use it to gate redundant publishes; read-write
    /// handles let the writer refresh it on each commit.
    let publishedMin = Atomic<UInt64>(0)
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
    /// the `ADDBFTS` module installs it explicitly
    /// (`Database.enableFullTextSearch()`). Copied onto each read/write transaction
    /// so MATCH resolves uniformly; stays nil until enabled — a MATCH row source
    /// then throws a clear error instead.
    @_spi(ADDBEngine) public func installFTSEvaluator(_ evaluator: any FTSEvaluation) {
        for shard in shards {
            shard.lock.withLock { if $0.ftsEvaluator == nil { $0.ftsEvaluator = evaluator } }
        }
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
        self.shards = (0 ..< Self.readerShardCount).map { _ in ShardBox(ReaderShard(meta: meta)) }
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
        for shard in shards { shard.lock.withLock { $0.closed = true } }
    }

    /// Generation of the most recent commit.
    public var generation: UInt64 {
        shards[0].lock.withLock { $0.meta.generation }
    }

    /// Number of key-value pairs at the most recent commit.
    public var count: UInt64 {
        shards[0].lock.withLock { $0.meta.kvCount }
    }

    /// A point-in-time snapshot of long-reader pressure on page reclamation
    /// (see `ReaderPressure`). Reading it is observability ONLY — nothing here
    /// changes reclamation. Snapshot isolation *requires* the writer to keep
    /// pinning every page a still-open reader could see, so an old open snapshot
    /// necessarily holds the free list back and lets the file/mmap grow under
    /// write churn — inherent MVCC long-reader bloat, not a bug. Watch
    /// `readerLag`: a value that keeps climbing under sustained writes is the
    /// signature of a read snapshot held open too long. The remedy is always to
    /// shorten that reader — never to advance reclamation past it (that would
    /// break isolation).
    public var readerPressure: ReaderPressure {
        var current: UInt64 = 0
        var localMin: UInt64?
        for (index, shard) in shards.enumerated() {
            shard.lock.withLock { state in
                if index == 0 { current = state.meta.generation }
                if let m = state.minGeneration { localMin = min(m, localMin ?? m) }
            }
        }
        // The cross-process reader table pins reclamation too, so fold in its
        // minimum (a read-only atomic scan of the shared slots), exactly as the
        // writer does when it computes its reclaim floor.
        let foreignMin = readerTable.minimumGeneration()
        let oldest: UInt64? =
            switch (localMin, foreignMin) {
                case (nil, nil): nil
                case (.some(let l), nil): l
                case (nil, .some(let f)): f
                case (.some(let l), .some(let f)): min(l, f)
            }
        return ReaderPressure(currentGeneration: current, oldestReaderGeneration: oldest)
    }

    /// A point-in-time reading of how far page reclamation is pinned behind the
    /// newest commit by the oldest still-open read snapshot. Purely diagnostic
    /// (see `Database.readerPressure`); it never influences reclamation.
    public struct ReaderPressure: Sendable {
        /// The newest committed generation at the moment of the reading.
        public let currentGeneration: UInt64
        /// Generation of the oldest read snapshot still open anywhere (this
        /// process's readers folded with the cross-process reader table), or nil
        /// when no reader is active. Reclamation is pinned at this generation.
        public let oldestReaderGeneration: UInt64?
        /// `currentGeneration − oldestReaderGeneration` (0 when no reader is open):
        /// how many commit generations of freed pages reclamation is currently
        /// pinned behind. A lag that grows without bound under sustained writes is
        /// the signature of a read snapshot held open too long.
        public var readerLag: UInt64 {
            guard let oldest = oldestReaderGeneration, currentGeneration > oldest else { return 0 }
            return currentGeneration - oldest
        }
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
            let registration = try beginRead()
            defer { endRead(shard: registration.shard, generation: registration.meta.generation) }
            let txn = ReadTxn(
                resolver: CommittedResolver(
                    source: pager, pageCount: registration.meta.pageCount,
                    verifyChecksums: options.verifyChecksumsOnRead, ftsEvaluator: registration.fts),
                meta: registration.meta, schemaCache: relationSchemaCache)
            return try body(txn)
        }
    }

    /// Registers a reader in one stripe and returns its snapshot meta, the installed
    /// FTS evaluator (read in the same short stripe lock, so the read path takes no
    /// extra lock for it), and the stripe index (which `endRead` must pass back so the
    /// matching count is decremented). The evaluator is nil unless
    /// `enableFullTextSearch()` ran.
    func beginRead() throws(DBError) -> (meta: Meta, fts: (any FTSEvaluation)?, shard: Int) {
        // Round-robin the stripe so concurrent readers spread across the stripes
        // instead of piling onto one lock. Relaxed: only distribution depends on it.
        let shardIndex = Int(
            truncatingIfNeeded: shardCursor.wrappingAdd(1, ordering: .relaxed).oldValue
                & UInt64(Self.readerShardCount - 1))
        // Read-only handles have no writer in-process: refresh the committed
        // meta from the mapped meta pages (checksums make torn reads safe).
        let refreshed: Meta? =
            if options.readOnly {
                unsafe try? Meta.recover(meta0: pager.map.pageBytes(0), meta1: pager.map.pageBytes(1))
            } else {
                nil
            }
        let snapshot: (Meta, (any FTSEvaluation)?)? = shards[shardIndex].lock
            .withLock { state in
                guard !state.closed else { return nil }
                if let refreshed, refreshed.generation > state.meta.generation {
                    state.meta = refreshed
                }
                state.readers[state.meta.generation, default: 0] += 1
                return (state.meta, state.ftsEvaluator)
            }
        guard let snapshot else { throw DBError.databaseClosed }
        // A read-only handle has no in-process writer to keep its cross-process slot
        // fresh, so it must announce this reader's generation itself (a read-write
        // handle is the system's sole reclaimer and gates its own readers via the
        // per-stripe scan in `writeReclaimSnapshot`). Lowering only — a brand-new
        // reader holds the newest generation, so this fires only for the first reader.
        if options.readOnly { lowerPublishedReaderMin(snapshot.0.generation) }
        return (snapshot.0, snapshot.1, shardIndex)
    }

    func endRead(shard: Int, generation: UInt64) {
        shards[shard].lock
            .withLock { state in
                if let count = state.readers[generation] {
                    if count <= 1 {
                        state.readers.removeValue(forKey: generation)
                    } else {
                        state.readers[generation] = count - 1
                    }
                }
            }
        // Only read-only handles maintain their cross-process slot on the read path
        // (see `beginRead`); and only when the departing reader could have BEEN the
        // published minimum, since otherwise the global minimum is unchanged. The
        // refresh RAISES the slot as old snapshots drain, so a peer writer can
        // reclaim again — always to a value still ≤ every live reader.
        if options.readOnly, generation <= publishedMin.load(ordering: .acquiring) {
            refreshPublishedReaderMin()
        }
    }

    /// Lowers this handle's cross-process reader slot to `generation` if it is below
    /// the currently published value (0 = none ⇒ always set). Lowering is always safe
    /// (a smaller published minimum is conservative — it can only make a peer writer
    /// reclaim *less*). Read-only only.
    private func lowerPublishedReaderMin(_ generation: UInt64) {
        var current = publishedMin.load(ordering: .acquiring)
        while current == 0 || generation < current {
            let (exchanged, original) = publishedMin.compareExchange(
                expected: current, desired: generation, ordering: .acquiringAndReleasing)
            if exchanged {
                readerTable.publish(minGeneration: generation)
                return
            }
            current = original
        }
    }

    /// Recomputes the exact in-process minimum live-reader generation across every
    /// stripe and publishes it (0 = none). Safe as a RAISE because a reader
    /// registering during the scan holds the newest committed generation (≥ the
    /// computed minimum), and an older reader is stably present in some stripe's
    /// histogram, so the scan sees it. Read-only only.
    private func refreshPublishedReaderMin() {
        var globalMin: UInt64?
        for shard in shards {
            shard.lock.withLock { state in
                if let m = state.minGeneration { globalMin = min(m, globalMin ?? m) }
            }
        }
        let value = globalMin ?? 0
        publishedMin.store(value, ordering: .releasing)
        readerTable.publish(minGeneration: value)
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
        guard let (meta, reclaimLimit, fts) = writeReclaimSnapshot() else {
            throw DBError.databaseClosed
        }

        let ctx = TxnContext(source: pager, meta: meta)
        ctx.appendCursorEnabled = options.execution.insert == .appendCursor
        ctx.insertHoistEnabled = options.execution.insert == .hoisted
        ctx.triggerEngine = triggerEngineBox.withLock { $0 }
        ctx.ftsEvaluator = fts
        ctx.now = options.now
        try FreeList.harvest(ctx: ctx, upTo: reclaimLimit)
        let baselineMain = ctx.meta.mainTree

        let txn = WriteTxn(ctx: ctx)
        let result = try body(txn)
        try ctx.participant?.serialize(into: ctx)

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
        publishCommittedMeta(newMeta)
        if let state = ctx.relation { relationSchemaCache.publish(state.schema) }
        return result
    }

    /// Snapshots the base meta plus the page-reclaim limit for a write. Runs ONLY on
    /// the (single) writer thread — `writeSync` and the group-commit drain both route
    /// here, and both are serialized by `writerThread`, so there is never a second
    /// writer racing meta publication.
    ///
    /// It scans EVERY reader stripe (each under its own short lock) for the minimum
    /// live-reader generation, folds in the cross-process reader table, and derives
    /// `reclaimLimit`. That per-stripe minimum is a correct LOWER BOUND on every live
    /// reader's snapshot generation: an older reader is stably present in its stripe
    /// (registered before this scan) and is seen; a reader registering during the scan
    /// holds the current committed generation (all stripes still carry it — no commit
    /// has happened), which `reclaimLimit` never reaches (it lags one generation). The
    /// exact in-process minimum is republished to this handle's slot so a peer process
    /// (and this handle's own `foreignMin` fold) sees a fresh, correct bound.
    func writeReclaimSnapshot() -> (meta: Meta, reclaimLimit: UInt64, fts: (any FTSEvaluation)?)? {
        readerTable.sweepStaleSlots()
        var meta: Meta?
        var closed = false
        var fts: (any FTSEvaluation)?
        var localMin: UInt64?
        for (index, shard) in shards.enumerated() {
            shard.lock.withLock { state in
                if index == 0 {
                    meta = state.meta
                    closed = state.closed
                    fts = state.ftsEvaluator
                }
                if let m = state.minGeneration { localMin = min(m, localMin ?? m) }
            }
        }
        guard let meta, !closed else { return nil }
        let localMinValue = localMin ?? UInt64.max
        // Keep this handle's slot fresh with the exact in-process minimum (raises it as
        // old readers drain; publishes 0 when none). Done BEFORE reading `foreignMin`
        // so the fold below sees the current value.
        let published = localMinValue == UInt64.max ? 0 : localMinValue
        publishedMin.store(published, ordering: .releasing)
        readerTable.publish(minGeneration: published)
        let foreignMin = readerTable.minimumGeneration() ?? UInt64.max
        return (meta, meta.reclaimLimit(minReader: min(localMinValue, foreignMin)), fts)
    }

    /// Publishes a freshly committed meta to every reader stripe, so subsequent
    /// `beginRead`s snapshot the new generation. Runs once per commit on the (single)
    /// writer thread. A reader observing a stripe mid-update still sees a fully valid
    /// committed meta (the old one or the new one) — both generations are durable, so
    /// cross-stripe skew during the loop only means some readers briefly snapshot one
    /// generation older, which is a legal snapshot.
    func publishCommittedMeta(_ newMeta: Meta) {
        for shard in shards { shard.lock.withLock { $0.meta = newMeta } }
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
                                    try Self.withRawSpan(over: raw) { (span: RawSpan) throws(DBError) in try body(span)
                                    })
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
        unsafe try key.withUnsafeBytesThrowing { keyBytes throws(DBError) in
            unsafe try value.withUnsafeBytesThrowing { valueBytes throws(DBError) in
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
