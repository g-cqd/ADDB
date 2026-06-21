import ADConcurrency
public import ADDB
// `DBError` (thrown across this façade's public API) moved to `ADSQLModel` in the ADSQL↔ADDB
// inversion; it appears in public signatures here, so the import is `public`.
public import ADSQLModel
// `QualityOfService` (and `ProcessInfo` for the default) appear in this file's
// public API, so Foundation is re-exported. Under `InternalImportsByDefault` a
// plain `import` would make those types `internal` and reject the public
// signatures.
public import Foundation

/// An async façade over a single ``ADDB/Database`` handle: **concurrent async
/// reads** and **serialized async writes**, honest to the engine's
/// single-writer / wait-free-reader MVCC model.
///
/// ## The concurrency model (and its honesty)
///
/// The ADDB engine is single-writer / wait-free-reader. Its `read` and
/// `writeSync` entry points are *synchronous and blocking*. This façade does not
/// reimplement any storage — it wraps those two calls so they fit structured
/// concurrency without blocking Swift's cooperative thread pool:
///
/// - **Reads run concurrently.** Each ``read(qos:_:)`` / ``query(qos:_:)`` runs
///   the engine's blocking `read` on a worker drawn from a small bounded thread
///   pool (``ADConcurrency/BlockingOffloadPool``), over its own immutable MVCC snapshot. Many reads
///   proceed at once across the pool's workers; none blocks the writer or the
///   cooperative pool. The bound is the pool's `readConcurrency`, so the façade
///   cannot fan out unbounded blocking work.
///
/// - **Writes are serialized.** Every ``write(qos:_:)`` funnels through ONE path:
///   a single dedicated writer thread (a one-worker ``ADConcurrency/BlockingOffloadPool``), entered
///   via a ``DatabaseWriter`` actor. At most one write is in flight, and writes
///   execute in submission order. This is faithful to the engine, which itself
///   runs every `writeSync` on one internal serial thread — the façade adds no
///   write concurrency and advertises none.
///
/// A *single* `Database` handle backs both paths: the engine already serves any
/// number of concurrent readers from one handle (reader registration is
/// internally synchronized), so pooling handles would be redundant and would
/// multiply the `mmap` reservation. What this façade bounds instead is the number
/// of *threads* doing blocking work. (For the rarer case where independent read
/// handles are wanted — e.g. to spread page-cache residency — ``PooledDatabase``
/// adapts a handle to `ADConcurrency.ResourcePool`.)
///
/// ## Cancellation
///
/// A blocking engine call cannot itself be interrupted mid-flight, so this façade
/// honors cancellation at the *boundaries*: a ``read(qos:_:)`` or ``write(qos:_:)``
/// invoked on an already-cancelled task throws `CancellationError` before any work
/// is dispatched. Once a job has been handed to a worker it runs to completion
/// (the snapshot read finishes, or the write commits or rolls back as a unit).
public final class AsyncDatabase: Sendable {
    /// The single shared engine handle. `Database` is `Sendable` and serves
    /// concurrent readers from one handle; the writer actor serializes writes.
    private let database: Database
    /// The bounded pool that runs blocking `read` calls off the cooperative pool.
    private let readPool: BlockingOffloadPool
    /// The serialized writer (actor funnel + single writer thread).
    private let writer: DatabaseWriter

    /// The on-disk path of the underlying database.
    public var path: String { database.path }

    /// Generation of the most recent commit (a cheap, synchronized engine read).
    public var generation: UInt64 { database.generation }

    /// Number of key/value pairs at the most recent commit.
    public var count: UInt64 { database.count }

    /// Open (or create) the database at `path` and build the async façade.
    ///
    /// - Parameters:
    ///   - path: Filesystem path passed straight to ``ADDB/Database/open(at:options:)``.
    ///   - options: Engine open options (durability, map size, read-only, …).
    ///   - readConcurrency: Maximum number of reads executing blocking engine work
    ///     at once. Floored at 1; defaults to the active processor count, a
    ///     sensible match for a server fronting this façade. Writes are always
    ///     serialized regardless of this value.
    ///   - qualityOfService: QoS for the read/write worker threads. Database work
    ///     is typically awaited by a caller, so `.userInitiated` by default.
    /// - Throws: ``ADDB/DBError`` if the engine cannot open the file.
    public init(
        path: String,
        options: DatabaseOptions = DatabaseOptions(),
        readConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        qualityOfService: QualityOfService = .userInitiated
    ) throws(DBError) {
        let database = try Database.open(at: path, options: options)
        self.database = database
        self.readPool = BlockingOffloadPool(
            width: max(1, readConcurrency), qualityOfService: qualityOfService)
        self.writer = DatabaseWriter(
            database: database, qualityOfService: qualityOfService)
    }

    /// Adopt an already-open ``ADDB/Database`` (e.g. one shared with other
    /// subsystems) under the async façade. The façade does not take ownership of
    /// the handle's lifetime beyond its own worker threads.
    public init(
        adopting database: Database,
        readConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        qualityOfService: QualityOfService = .userInitiated
    ) {
        self.database = database
        self.readPool = BlockingOffloadPool(
            width: max(1, readConcurrency), qualityOfService: qualityOfService)
        self.writer = DatabaseWriter(
            database: database, qualityOfService: qualityOfService)
    }

    // MARK: - Reads (concurrent)

    /// Run `body` against an immutable snapshot of the newest committed
    /// generation, concurrently with other reads and with the writer.
    ///
    /// The closure executes synchronously on a read-pool worker thread (never the
    /// cooperative pool). It borrows a ``ADDB/ReadTxn`` for its duration; the
    /// transaction is noncopyable and cannot escape, so the snapshot is released
    /// when `body` returns. The result must be `Sendable` to return to the caller.
    ///
    /// - Throws: `CancellationError` if the task is already cancelled at entry;
    ///   otherwise any ``ADDB/DBError`` the body throws.
    public func read<R: Sendable>(
        qos: QualityOfService? = nil,
        _ body: @Sendable @escaping (borrowing ReadTxn) throws(DBError) -> R
    ) async throws -> R {
        try Task.checkCancellation()
        let database = self.database
        return try await readPool.run { () throws -> R in
            // `Database.read` registers a reader, runs `body` over the snapshot,
            // and deregisters — all synchronously on this worker thread.
            try database.read { txn throws(DBError) in try body(txn) }
        }
    }

    /// Convenience read for a single key on a fresh snapshot. Returns the value
    /// bytes, or `nil` when the key is absent.
    public func get(_ key: [UInt8], qos: QualityOfService? = nil) async throws -> [UInt8]? {
        try await read(qos: qos) { txn throws(DBError) in try txn.get(key) }
    }

    /// Convenience membership test for a single key on a fresh snapshot.
    public func contains(_ key: [UInt8], qos: QualityOfService? = nil) async throws -> Bool {
        try await read(qos: qos) { txn throws(DBError) in try txn.contains(key) }
    }

    /// Alias for ``read(qos:_:)`` reading as "run a query over a snapshot",
    /// for call sites where the intent is querying rather than a point read.
    public func query<R: Sendable>(
        qos: QualityOfService? = nil,
        _ body: @Sendable @escaping (borrowing ReadTxn) throws(DBError) -> R
    ) async throws -> R {
        try await read(qos: qos, body)
    }

    // MARK: - Writes (serialized)

    /// Run one exclusive write transaction, serialized against every other write.
    ///
    /// The closure executes synchronously on the single writer thread; on a
    /// thrown error nothing is persisted, and on return the transaction is durably
    /// committed per the database's durability profile. Writes never interleave —
    /// at most one is in flight and they run in submission order.
    ///
    /// - Throws: `CancellationError` if the task is already cancelled at entry;
    ///   otherwise any ``ADDB/DBError`` the body throws.
    @discardableResult
    public func write<R: Sendable>(
        qos: QualityOfService? = nil,
        _ body: @Sendable @escaping (borrowing WriteTxn) throws(DBError) -> R
    ) async throws -> R {
        try Task.checkCancellation()
        return try await writer.perform(body)
    }

    /// Convenience write: insert or replace a single key/value pair.
    public func put(_ key: [UInt8], _ value: [UInt8], qos: QualityOfService? = nil) async throws {
        try await write(qos: qos) { txn throws(DBError) in try txn.put(key, value) }
    }

    /// Convenience write: delete a key, returning whether it existed.
    @discardableResult
    public func delete(_ key: [UInt8], qos: QualityOfService? = nil) async throws -> Bool {
        try await write(qos: qos) { txn throws(DBError) in try txn.delete(key) }
    }

    // MARK: - Lifecycle

    /// Mark the underlying handle closed (new transactions fail) and tear down the
    /// worker threads. The `mmap` / file descriptor are released when the last
    /// reference to the handle goes away.
    public func close() async {
        database.close()
        readPool.shutdown()
        await writer.shutdown()
    }
}
