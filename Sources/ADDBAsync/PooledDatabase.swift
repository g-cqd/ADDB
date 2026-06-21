public import ADConcurrency
public import ADDB
public import ADSQLModel  // DBError (moved here in the ADSQL↔ADDB inversion); in public signatures
// `QualityOfService` appears in this file's public API (see ``AsyncDatabase``).
public import Foundation

/// A pool-friendly wrapper around an ``ADDB/Database`` handle, conforming to
/// ``ADConcurrency/PooledResource`` so independent read handles can be managed by
/// an ``ADConcurrency/ResourcePool``.
///
/// ## When you'd want this over ``AsyncDatabase``
///
/// ``AsyncDatabase`` backs all reads with a *single* shared `Database` handle —
/// the right default, because the engine already serves any number of concurrent
/// readers from one handle (reader registration is internally synchronized) and a
/// second handle only duplicates the `mmap` reservation. ``PooledDatabase`` exists
/// for the rarer case where genuinely **independent handles** are wanted — e.g. to
/// spread page-cache residency, or to bound work by handle rather than by thread —
/// by slotting into the family's generic ``ADConcurrency/ResourcePool`` exactly as
/// the apple-docs server's `StorageConnection` does.
///
/// Each handle is opened **read-only** (`readOnly: true`): a pool is a read
/// construct, and the engine permits only one writer process-wide, so a pool of
/// writable handles would be a category error. Writes still go through
/// ``AsyncDatabase`` / ``DatabaseWriter``.
///
/// `Database` is a `final class Sendable`, so this wrapper is a trivially
/// `Sendable` value carrying one reference.
public struct PooledDatabase: PooledResource {
    /// The wrapped read-only engine handle. One handle is touched by one task at a
    /// time under ``ADConcurrency/ResourcePool``'s checkout discipline.
    public let database: Database

    /// Open a read-only handle at `path`, or `nil` if the engine cannot open the
    /// file (the all-or-nothing contract ``ADConcurrency/ResourcePool`` relies on).
    ///
    /// This is the ``ADConcurrency/PooledResource`` requirement; it opens with
    /// `createIfMissing: false` because a pool reads an existing database.
    public init?(path: String) {
        guard
            let database = try? Database.open(
                at: path,
                options: DatabaseOptions(readOnly: true, createIfMissing: false))
        else { return nil }
        self.database = database
    }

    /// Adopt an already-open handle (e.g. one opened with custom options).
    public init(adopting database: Database) {
        self.database = database
    }
}

/// A concurrent **read-only** async façade backed by a pool of independent
/// ``PooledDatabase`` handles.
///
/// This is the pooled counterpart to ``AsyncDatabase``'s read path: instead of one
/// shared handle, each read leases a distinct handle from an
/// ``ADConcurrency/ResourcePool`` for its duration and runs the engine's blocking
/// `read` on an offload worker. Concurrency is bounded by the pool size *and* the
/// worker count, whichever is smaller. There is no write path here by design —
/// every handle is read-only.
///
/// Most servers should prefer ``AsyncDatabase`` (single handle, lighter `mmap`
/// footprint). Reach for this only when independent handles are the point.
public final class PooledReadDatabase: Sendable {
    private let pool: ResourcePool<PooledDatabase>
    private let readPool: BlockingOffloadPool

    /// The number of independent handles in the pool (its maximum concurrent reads).
    public var handleCount: Int { pool.count }

    /// Open `count` independent read-only handles at `path` and front them with an
    /// offload pool of `count` workers.
    ///
    /// - Returns: `nil` if any handle fails to open (all-or-nothing, matching
    ///   ``ADConcurrency/ResourcePool``).
    public init?(
        path: String,
        count: Int,
        qualityOfService: QualityOfService = .userInitiated
    ) {
        let bounded = max(1, count)
        guard let pool = ResourcePool<PooledDatabase>(path: path, count: bounded) else {
            return nil
        }
        self.pool = pool
        self.readPool = BlockingOffloadPool(width: bounded, qualityOfService: qualityOfService)
    }

    /// Run `body` against an immutable snapshot taken on a leased handle.
    ///
    /// Leases a handle, runs the engine's blocking `read` on an offload worker, and
    /// returns the handle to the pool on completion (the noncopyable
    /// ``ADConcurrency/ResourceLease`` auto-returns on scope exit). Throws
    /// ``ADDB/DBError`` `databaseClosed`-style exhaustion semantics via
    /// ``PoolDrainedError`` when every handle is momentarily checked out.
    ///
    /// - Throws: `CancellationError` if the task is already cancelled at entry;
    ///   ``PoolDrainedError`` if the pool is momentarily drained; otherwise any
    ///   ``ADDB/DBError`` the body throws.
    public func read<R: Sendable>(
        _ body: @Sendable @escaping (borrowing ReadTxn) throws(DBError) -> R
    ) async throws -> R {
        try Task.checkCancellation()
        let pool = self.pool
        return try await readPool.run { () throws -> R in
            guard let lease = pool.lease() else { throw PoolDrainedError() }
            // The lease auto-returns the handle to the pool when this scope exits,
            // including on a thrown error from `read`.
            return try lease.resource.database.read { txn throws(DBError) in try body(txn) }
        }
    }

    /// Convenience point read on a leased handle's snapshot.
    public func get(_ key: [UInt8]) async throws -> [UInt8]? {
        try await read { txn throws(DBError) in try txn.get(key) }
    }

    /// Tear down the worker threads. The handles release their `mmap` / file
    /// descriptors when the pool is deallocated.
    public func shutdown() {
        readPool.shutdown()
    }
}

/// Thrown by ``PooledReadDatabase/read(_:)`` when every pooled handle is currently
/// checked out. Distinct from ``ADDB/DBError`` because it is a *pool-capacity*
/// condition, not an engine error — the caller decides the policy (retry, back
/// off, or surface it).
public struct PoolDrainedError: Error, Sendable, CustomStringConvertible {
    public init() {}
    public var description: String { "the database handle pool is momentarily drained" }
}
