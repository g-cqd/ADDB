public import ADSQLModel

/// Resolves page numbers to page bytes. Read transactions resolve straight
/// from committed storage; write transactions overlay their dirty table.
@_spi(ADDBEngine) public protocol PageResolver {
    func resolvePage(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer
    /// Advisory readahead for an upcoming contiguous page run (forward scans).
    func prefetch(fromPage: UInt64, count: Int)
    /// Configured scan readahead window in pages a cursor should keep in flight
    /// (0 disables). Forward scans read this once at creation.
    var prefetchWindow: Int { get }
    /// The full-text-search query evaluator for this transaction, copied from the
    /// database when `Database.enableFullTextSearch()` has installed one (nil
    /// otherwise). The executor's MATCH row source reads it here so both the read
    /// (committed) and write (overlay) paths reach the same evaluator.
    var ftsEvaluator: (any FTSEvaluation)? { get }
}

extension PageResolver {
    /// Default: prefetch is a no-op (write contexts and test resolvers don't
    /// scan-prefetch; only the mapped committed reader forwards it).
    @inline(__always)
    @_spi(ADDBEngine) public func prefetch(fromPage: UInt64, count: Int) {}
    @inline(__always)
    @_spi(ADDBEngine) public var prefetchWindow: Int { 0 }
    /// Default: no FTS query evaluator (raw key/value resolvers and test resolvers
    /// never run MATCH). `TxnContext`/`CommittedResolver` override with the value
    /// copied from the database.
    @inline(__always)
    @_spi(ADDBEngine) public var ftsEvaluator: (any FTSEvaluation)? { nil }
}

/// Committed-page reader (mmap in production, dictionaries in tests).
@_spi(ADDBEngine) public protocol PageSource: AnyObject {
    func page(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer
    func prefetch(fromPage: UInt64, count: Int)
    var prefetchWindow: Int { get }
}

extension PageSource {
    @inline(__always)
    @_spi(ADDBEngine) public func prefetch(fromPage: UInt64, count: Int) {}
    @inline(__always)
    @_spi(ADDBEngine) public var prefetchWindow: Int { 0 }
}

/// Storage→relational seam. The relational layer's per-transaction state rides a write transaction
/// behind this protocol, so storage drives its rollback (`captureState`/`restoreState`) and commit
/// (`serialize`) WITHOUT naming `RelationState`/`Value`/`Catalog`. The concrete participant lives in
/// the relational module (`RelationParticipant`) — mirroring the established `TriggerFiring` /
/// `FTSEvaluation` seams that already keep storage from naming the SQL/query types.
@_spi(ADDBEngine) public protocol RelationalParticipant: AnyObject {
    /// Commit: serialize accumulated relational changes (catalog, sequences) into the txn's pages.
    func serialize(into ctx: TxnContext) throws(DBError)
    /// Rollback: capture the participant's state for a stacked-request restore point.
    func captureState() -> Any?
    /// Rollback: restore a previously captured state.
    func restoreState(_ token: Any?)
}

/// Page allocation state for one write transaction. Fresh pages (allocated
/// and freed within the same transaction, never visible to any reader) are
/// recycled immediately; committed pages freed here must wait for readers
/// and are handed to the free-list at commit.
@_spi(ADDBEngine) public struct PageAllocator {
    /// Next never-used page (high-water mark, becomes meta.pageCount).
    @_spi(ADDBEngine) public var highWater: UInt64
    /// Reusable pages harvested from the free-list (older generations whose
    /// readers are gone) plus same-transaction fresh frees.
    @_spi(ADDBEngine) public var pool: [UInt64]
    /// While the free-list serializes itself at commit time, the pool is
    /// frozen (its contents are being written out) and all allocation comes
    /// from the high-water mark.
    @_spi(ADDBEngine) public var highWaterOnly = false

    @_spi(ADDBEngine) public init(highWater: UInt64, pool: [UInt64] = []) {
        self.highWater = highWater
        self.pool = pool
    }

    @_spi(ADDBEngine) public mutating func allocate() -> UInt64 {
        if !highWaterOnly, let reused = pool.popLast() { return reused }
        defer { highWater += 1 }
        return highWater
    }

    /// Allocate bypassing the recycled pool (used by free-list maintenance to
    /// avoid consuming the pool it is itself rebuilding).
    @_spi(ADDBEngine) public mutating func allocateHighWater() -> UInt64 {
        defer { highWater += 1 }
        return highWater
    }
}

/// Mutable state of one write transaction. Single-threaded by construction:
/// only the writer loop touches it.
@_spi(ADDBEngine) public final class TxnContext: PageResolver, OverflowPager {
    @_spi(ADDBEngine) public let source: any PageSource
    @_spi(ADDBEngine) public var meta: Meta
    @_spi(ADDBEngine) public var allocator: PageAllocator
    /// Pages written this transaction (always includes every allocated page).
    @_spi(ADDBEngine) public var dirty: [UInt64: PageBuf] = [:]
    /// Committed pages this transaction stopped referencing: reclaimable only
    /// once concurrent readers move past this generation.
    @_spi(ADDBEngine) public var pendingFree: [UInt64] = []

    /// Reusable encode buffers for the insert path: one for the row record, one for
    /// each index entry key (used sequentially). `putBytes` copies the bytes into
    /// the page, so reusing the buffer across rows in a transaction avoids a fresh
    /// allocation per row. Query/read paths never touch these.
    var recordScratch: [UInt8] = []
    var indexKeyScratch: [UInt8] = []
    /// Warm rightmost-leaf append cache per table tree (keyed by tableId), used by
    /// the opt-in `appendCursor` insert path. Writer-confined; cleared on request
    /// rollback (below). The per-entry `rootPage` guard catches every other tree
    /// mutation (a non-append re-shadows the root), so a stale entry never appends.
    var appendCache: [UInt32: BTree.AppendCache] = [:]
    /// Whether the opt-in `appendCursor` insert fast path is active for this
    /// transaction (`DatabaseOptions.execution.insert ==.appendCursor`); set once
    /// at ctx creation. Default off → the proven descent path.
    var appendCursorEnabled = false

    /// Per-transaction cache of a table's owned secondary-index names, sorted,
    /// keyed by tableId — so the INSERT path pays the per-row filter+sort+allocation
    /// of the index roster once per table (every insert form; not gated). The
    /// index-name set is invariant within a single INSERT statement (triggers cannot
    /// run DDL), so this is filled lazily on first insert and invalidated only by
    /// index-set DDL (`createIndex`/`dropIndex`/`dropTable`) and request-scope
    /// rollback (a rolled-back CREATE/DROP INDEX would otherwise leave a stale roster).
    var hoistedRoster: [UInt32: [String]] = [:]
    /// Whether the opt-in `hoisted` insert fast path is active for this transaction
    /// (`DatabaseOptions.execution.insert ==.hoisted`); set once at ctx creation.
    /// Gates the COW write-back elision (dropping `ctx.relation`'s alias so the
    /// write loop mutates in place). Default off → the proven per-row write-back.
    /// (The index-roster cache above is unconditional, independent of this flag.)
    var insertHoistEnabled = false

    /// The relational layer's per-transaction state, held OPAQUELY behind the
    /// `RelationalParticipant` seam so storage never names `RelationState`/`Value`. The relational
    /// module installs a participant lazily (via the `relation` accessor in `RelationParticipant.swift`)
    /// on first relational use; storage only drives its snapshot/restore (request rollback) and
    /// serialize (commit). Writer-confined.
    @_spi(ADDBEngine) public var participant: (any RelationalParticipant)?

    /// Active NEW/OLD row frame while a trigger body executes. The write
    /// path consults it so trigger-body expressions can read `new.col`/`old.col`;
    /// nil outside a trigger. Stacked frames restore the prior frame on return.
    @_spi(ADDBEngine) public var triggerFrame: TriggerFrame?
    /// Trigger recursion depth: bumped around each fired trigger body so a
    /// self-referential trigger errors instead of looping forever.
    @_spi(ADDBEngine) public var triggerDepth: UInt32 = 0
    /// The SQL-layer trigger engine, installed by the SQL layer onto the database
    /// and copied onto each write context at creation. nil when no SQL layer is
    /// wired (raw key/value use), so DML simply never fires triggers.
    @_spi(ADDBEngine) public var triggerEngine: (any TriggerFiring)?
    /// Opaque per-transaction cache owned by the trigger engine (a box of parsed
    /// trigger definitions). Storage never inspects it; it dies with the txn, so a
    /// parsed definition cannot outlive its source text. Writer-confined → no lock.
    @_spi(ADDBEngine) public var triggerCache: AnyObject?
    /// The SQL-layer FTS query evaluator, installed by `ADDBFTS` onto
    /// the database and copied onto each write context at creation (mirroring
    /// `triggerEngine`). nil when full-text search is not enabled, so a write that
    /// touches an FTS table's MATCH source on the overlay sees the same evaluator a
    /// read would.
    @_spi(ADDBEngine) public var ftsEvaluator: (any FTSEvaluation)?

    /// The wall clock the `.datetimeNow` column default resolves against (epoch
    /// seconds), copied from `Database.options.now` at context creation so a pinned
    /// test clock reaches the engine's default resolver. Defaults to the live clock.
    @_spi(ADDBEngine) public var now: @Sendable () -> Int64 = CivilTime.liveEpochSeconds

    /// Group-commit nesting: stacked micro-transactions bump the epoch; pages
    /// dirtied by earlier requests are cloned on first touch so a failing
    /// request can restore them (see RequestUndo).
    var requestEpoch: UInt32 = 0
    var undoReplaced: [(pageNo: UInt64, previous: PageBuf)] = []
    var undoAllocated: [UInt64] = []
    var undoFreedOwned: [(pageNo: UInt64, buf: PageBuf)] = []

    @_spi(ADDBEngine) public init(source: any PageSource, meta: Meta, pool: [UInt64] = []) {
        self.source = source
        self.meta = meta
        self.allocator = PageAllocator(highWater: meta.pageCount, pool: pool)
    }

    // MARK: - Page access

    @_spi(ADDBEngine) public func resolvePage(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer {
        if let buf = dirty[pageNo] { return unsafe buf.readOnly }
        // Committed pages live in [0, meta.pageCount); a higher number is a corrupt
        // in-page pointer that would otherwise read mapped-but-uncommitted (zeroed)
        // space without faulting (integrity R2). Pages allocated this transaction
        // are in `dirty` above, so they bypass this bound.
        guard pageNo < meta.pageCount else { throw DBError.corruptPage(pageNo: pageNo) }
        return unsafe try source.page(pageNo)
    }

    @inline(__always)
    @_spi(ADDBEngine) public func owns(_ pageNo: UInt64) -> Bool { dirty[pageNo] != nil }

    /// Brand-new zeroed page owned by this transaction.
    @_spi(ADDBEngine) public func allocatePage() -> (pageNo: UInt64, buf: PageBuf) {
        let pageNo = allocator.allocate()
        let buf = PageBuf()
        buf.requestEpoch = requestEpoch
        dirty[pageNo] = buf
        if requestEpoch != 0 { undoAllocated.append(pageNo) }
        return (pageNo, buf)
    }

    /// COW fault-in: returns a mutable buffer for `pageNo`. If the page is
    /// committed, it is copied to a freshly allocated page number (the old one
    /// goes to pendingFree) — COW-once-per-transaction. Under group commit,
    /// pages owned by an *earlier request* are additionally cloned on first
    /// touch so the current request can be rolled back alone.
    @_spi(ADDBEngine) public func shadow(_ pageNo: UInt64) throws(DBError) -> (pageNo: UInt64, buf: PageBuf) {
        if let buf = dirty[pageNo] {
            if requestEpoch != 0, buf.requestEpoch != requestEpoch {
                let clone = unsafe PageBuf(copying: buf.readOnly)
                clone.requestEpoch = requestEpoch
                dirty[pageNo] = clone
                undoReplaced.append((pageNo: pageNo, previous: buf))
                return (pageNo, clone)
            }
            return (pageNo, buf)
        }
        let copy = unsafe PageBuf(copying: try source.page(pageNo))
        copy.requestEpoch = requestEpoch
        let newNo = allocator.allocate()
        dirty[newNo] = copy
        pendingFree.append(pageNo)
        if requestEpoch != 0 { undoAllocated.append(newNo) }
        return (newNo, copy)
    }

    /// Releases a page this transaction no longer references.
    @_spi(ADDBEngine) public func freePage(_ pageNo: UInt64) {
        if let buf = dirty.removeValue(forKey: pageNo) {
            // Never visible to anyone: recycle immediately.
            allocator.pool.append(pageNo)
            if requestEpoch != 0 { undoFreedOwned.append((pageNo: pageNo, buf: buf)) }
        } else {
            pendingFree.append(pageNo)
        }
    }

    // MARK: - Group-commit request nesting

    /// Starts a new stacked micro-transaction scope.
    func beginRequestScope() {
        requestEpoch &+= 1
        if requestEpoch == 0 { requestEpoch = 1 }
        undoReplaced.removeAll(keepingCapacity: true)
        undoAllocated.removeAll(keepingCapacity: true)
        undoFreedOwned.removeAll(keepingCapacity: true)
    }

    /// Rolls back everything the current request scope did to the page state.
    /// Scalar state (meta, pendingFree, pool, highWater) is restored by the
    /// caller's TxnRestorePoint.
    func rollbackRequestScope() {
        for entry in undoReplaced { dirty[entry.pageNo] = entry.previous }
        for pageNo in undoAllocated { dirty.removeValue(forKey: pageNo) }
        for entry in undoFreedOwned { dirty[entry.pageNo] = entry.buf }
        // The append cache may point at a leaf whose appends this scope just undid;
        // drop it so the next append re-establishes it from the restored tree.
        appendCache.removeAll(keepingCapacity: true)
        // A rolled-back CREATE/DROP INDEX in this scope may have changed a table's
        // index roster; drop the hoisted cache so it re-derives from the restored set.
        hoistedRoster.removeAll(keepingCapacity: true)
    }

    // MARK: - OverflowPager

    @_spi(ADDBEngine) public func allocateOverflowPage() throws(DBError) -> (
        pageNo: UInt64, buf: PageBuf
    ) {
        allocatePage()
    }

    @_spi(ADDBEngine) public func readOverflowPage(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer {
        unsafe try resolvePage(pageNo)
    }

    @_spi(ADDBEngine) public func freeOverflowPage(_ pageNo: UInt64) throws(DBError) {
        freePage(pageNo)
    }
}

extension TxnContext {
    /// Fires AFTER triggers for a row change through the installed engine; a
    /// no-op when no engine is wired (so non-SQL writers pay nothing).
    func fireTriggers(
        event: TriggerEvent, table: String, old: [Value]?, new: [Value]?
    ) throws(DBError) {
        // Fast path: skip the engine (and its existential dispatch) entirely unless
        // a trigger actually exists. The DML path always has `relation` loaded by
        // the time it fires, so a trigger-free write pays only an optional + a
        // dictionary-empty check per row — cheaper than the old static call.
        guard let triggerEngine, let relation, !relation.triggerTexts.isEmpty else { return }
        try triggerEngine.fire(self, event: event, table: table, old: old, new: new)
    }

    /// Names of triggers whose target is `table` (for DROP TABLE cascade); empty
    /// when no engine is wired.
    func triggerNamesTargeting(_ table: String) throws(DBError) -> [String] {
        guard let triggerEngine else { return [] }
        return try triggerEngine.triggerNames(targeting: table, in: self)
    }
}

/// Read-side resolver over committed pages only.
@_spi(ADDBEngine) public struct CommittedResolver: PageResolver {
    @_spi(ADDBEngine) public let source: any PageSource
    /// Snapshot's committed high-water: a committed tree never references a page
    /// number ≥ pageCount, so anything beyond it is a corrupt in-page pointer
    /// (which would read mapped-but-uncommitted space without faulting). `.max`
    /// leaves the bound off for low-level resolvers built without a meta.
    @_spi(ADDBEngine) public let pageCount: UInt64
    /// Verify each resolved page's checksum before use (opt-in; off on the hot
    /// path). Catches the full corruption class — a tampered cellCount/keyLen
    /// changes the page bytes, so the stored XXH64 no longer matches.
    @_spi(ADDBEngine) public let verifyChecksums: Bool
    /// The FTS query evaluator for this read snapshot, copied from the database
    /// (nil unless `Database.enableFullTextSearch()` installed one). See
    /// ``PageResolver/ftsEvaluator``.
    @_spi(ADDBEngine) public let ftsEvaluator: (any FTSEvaluation)?

    @_spi(ADDBEngine) public init(
        source: any PageSource, pageCount: UInt64 = .max, verifyChecksums: Bool = false,
        ftsEvaluator: (any FTSEvaluation)? = nil
    ) {
        self.source = source
        self.pageCount = pageCount
        self.verifyChecksums = verifyChecksums
        self.ftsEvaluator = ftsEvaluator
    }
    @inline(__always)
    @_spi(ADDBEngine) public func resolvePage(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer {
        guard pageNo < pageCount else { throw DBError.corruptPage(pageNo: pageNo) }
        let page = unsafe try source.page(pageNo)
        if verifyChecksums {
            // A matching XXH64 proves the page is byte-identical to when written,
            // so it subsumes — and is stricter than — the structural pass below.
            guard unsafe PageHeader.verifyChecksum(page, pageNo: pageNo) else {
                throw DBError.corruptPage(pageNo: pageNo)
            }
        } else {
            // Defense-in-depth baseline (no hashing): bounds-validate the slot
            // array and every cell's key/value ranges so a corrupt committed page
            // can neither trap in `rebasing:` nor hand out an in-page-but-wrong
            // key/value to a consumer.
            try unsafe Node.validate(page, pageNo: pageNo)
        }
        return unsafe page
    }
    @inline(__always)
    @_spi(ADDBEngine) public func prefetch(fromPage: UInt64, count: Int) {
        source.prefetch(fromPage: fromPage, count: count)
    }
    @inline(__always)
    @_spi(ADDBEngine) public var prefetchWindow: Int { source.prefetchWindow }
}
