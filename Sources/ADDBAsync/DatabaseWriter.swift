// The writer is `internal` (driven through ``AsyncDatabase``), so its use of
// `Database`/`WriteTxn`/`DBError` never crosses the package's public API — a plain
// `import` suffices.
import ADConcurrency
import ADDB
import ADSQLModel  // DBError (moved here in the ADSQL↔ADDB inversion)
import Foundation

/// The serialized write funnel for ``AsyncDatabase`` — the *one* async path
/// through which every write reaches the engine.
///
/// ## Why an actor, and what it actually guarantees
///
/// The ADDB engine is single-writer: `Database.writeSync` already runs every
/// write on one dedicated serial thread (`WriterThread`, FIFO, mutually
/// exclusive). This actor does **not** add a second writer or any write
/// concurrency — it would be dishonest to. Its job is purely to be the async
/// boundary:
///
/// 1. **Single funnel.** All writes go through `perform(_:)` on this one actor
///    instance, so there is exactly one async entry point — never a fan-out of
///    independent writers racing for the engine.
/// 2. **One worker thread.** The blocking `writeSync` call is offloaded to a
///    one-worker ``ADConcurrency/BlockingOffloadPool``. With a single worker, jobs run strictly one
///    at a time in submission order, mirroring the engine's own serial writer
///    thread, so the cooperative pool is never blocked by a commit.
/// 3. **Submission order.** `perform` enqueues onto the FIFO worker pool from the
///    actor's isolation, so writes are dispatched in call-arrival order.
///
/// Actor reentrancy note: `perform` suspends on a continuation while its job runs
/// on the worker, so a second `perform` can be admitted onto the actor during that
/// suspension. That is correct and intended — the admitted call only enqueues its
/// own job onto the **single-worker** pool, which serializes execution. At most
/// one write ever executes against the engine at a time; the actor + one-worker
/// pool + engine `WriterThread` form three nested serial gates, none of which
/// permits two concurrent commits.
///
/// This type is `internal`: callers drive it through ``AsyncDatabase/write(qos:_:)``.
actor DatabaseWriter {
    /// The shared engine handle. `Database` is `Sendable`; only this actor's
    /// worker ever calls its `writeSync`, so writes are single-threaded in
    /// practice even though the handle could technically be written from elsewhere.
    private let database: Database
    /// Exactly one worker: the structural guarantee that writes never overlap.
    private let executor: BlockingOffloadPool

    /// Build the writer over `database`, spinning up its single dedicated writer
    /// thread at `qualityOfService`.
    init(database: Database, qualityOfService: QualityOfService) {
        self.database = database
        self.executor = BlockingOffloadPool(width: 1, qualityOfService: qualityOfService)
    }

    /// Run one exclusive write transaction and suspend until it has committed (or
    /// thrown). Serialized against every other write through this writer.
    ///
    /// The `body` borrows a ``ADDB/WriteTxn`` on the writer thread; on a thrown
    /// error nothing is persisted, and on a clean return the transaction is durably
    /// committed per the database's durability profile. The `Sendable` result is
    /// delivered back to the awaiting task through the continuation.
    @discardableResult
    func perform<R: Sendable>(
        _ body: @Sendable @escaping (borrowing WriteTxn) throws(DBError) -> R
    ) async throws -> R {
        let database = self.database
        return try await executor.run { () throws -> R in
            // `Database.writeSync` itself runs this on the engine's serial writer
            // thread; we are already on the single offload worker, so this is the
            // one-and-only path a write can take.
            try database.writeSync { txn throws(DBError) in try body(txn) }
        }
    }

    /// Stop accepting writes and join the writer thread. Idempotent. Any already
    /// enqueued write is honored before the worker exits, so no continuation leaks.
    func shutdown() {
        executor.shutdown()
    }
}
