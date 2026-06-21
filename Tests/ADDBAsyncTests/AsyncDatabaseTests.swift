import ADDB
import ADSQLModel
import Foundation
import Testing

@testable import ADDBAsync

/// Behavioral characterization of the ``AsyncDatabase`` façade: that the async
/// surface preserves the engine's single-writer / wait-free-reader guarantees —
/// reads see committed writes, concurrent reads see a consistent snapshot, and
/// writes serialize without a data race. The suite is `.serialized` so the temp
/// databases (and their worker threads) don't contend for the box's resources;
/// concurrency *within* a test is the point, not concurrency across tests.
@Suite(.serialized)
struct AsyncDatabaseTests {
    // MARK: - Reads reflect writes

    @Test
    func `a write is visible to a subsequent async read`() async throws {
        try await withTempDBPath { path in
            let db = try AsyncDatabase(path: path)
            defer { Task { await db.close() } }

            try await db.put(key(1), bytes(42))
            let value = try await db.get(key(1))
            #expect(value.flatMap(uint64) == 42)

            // Overwrite, then re-read: the newest committed value wins.
            try await db.put(key(1), bytes(99))
            #expect(try await db.get(key(1)).flatMap(uint64) == 99)

            // A missing key reads as nil.
            #expect(try await db.get(key(7)) == nil)
            #expect(try await db.contains(key(7)) == false)
            #expect(try await db.contains(key(1)) == true)
        }
    }

    @Test
    func `delete through the façade removes the key for later reads`() async throws {
        try await withTempDBPath { path in
            let db = try AsyncDatabase(path: path)
            defer { Task { await db.close() } }

            try await db.put(key(5), bytes(500))
            #expect(try await db.get(key(5)).flatMap(uint64) == 500)

            let existed = try await db.delete(key(5))
            #expect(existed == true)
            #expect(try await db.get(key(5)) == nil)

            // Deleting an absent key reports it did not exist.
            #expect(try await db.delete(key(5)) == false)
        }
    }

    // MARK: - Concurrent reads see a consistent snapshot

    @Test
    func `many concurrent reads all succeed and agree on a consistent snapshot`() async throws {
        try await withTempDBPath { path in
            let db = try AsyncDatabase(path: path, readConcurrency: 8)
            defer { Task { await db.close() } }

            // Seed N keys in one transaction so they share a single commit
            // generation — every reader, whichever snapshot it lands on, must see
            // all of them (the commit is atomic).
            let n: UInt64 = 256
            try await db.write { txn throws(DBError) in
                for i in 0 ..< n { try txn.put(key(i), bytes(i &* 2)) }
            }

            // Fan out far more concurrent reads than the pool has workers, so the
            // offload queue genuinely interleaves them. Each read independently
            // verifies the full key set on its own snapshot.
            let readers = 64
            try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0 ..< readers {
                    group.addTask {
                        try await db.read { txn throws(DBError) in
                            for i in 0 ..< n {
                                guard let raw = try txn.get(key(i)), uint64(raw) == i &* 2 else {
                                    return false
                                }
                            }
                            // The snapshot's own count must reflect the seeded rows.
                            return txn.count == n
                        }
                    }
                }
                for try await ok in group { #expect(ok) }
            }
        }
    }

    @Test
    func `a read snapshot is stable even while a concurrent write advances the db`() async throws {
        try await withTempDBPath { path in
            let db = try AsyncDatabase(path: path, readConcurrency: 4)
            defer { Task { await db.close() } }

            try await db.put(key(0), bytes(0))
            let startGen = db.generation

            // A read captures the generation and count it observes; concurrently a
            // writer commits new keys. MVCC snapshot isolation guarantees the read
            // sees a single consistent generation, never a torn mixture of the
            // pre- and post-write states.
            async let readResult: (UInt64, UInt64) = db.read { txn throws(DBError) in
                (txn.generation, txn.count)
            }

            // Concurrently commit several new keys.
            for i in 1 ... 10 {
                try await db.put(key(UInt64(i)), bytes(UInt64(i)))
            }

            let (observedGen, observedCount) = try await readResult
            // The reader saw a consistent generation at or after the starting one.
            #expect(observedGen >= startGen)
            #expect(observedCount >= 1)
            // After the writes, the newest generation strictly advanced past start.
            #expect(db.generation > startGen)
            // And the final committed state has all 11 keys (0...10).
            let finalCount = try await db.read { txn throws(DBError) in txn.count }
            #expect(finalCount == 11)
        }
    }

    // MARK: - Writes serialize (no data race)

    @Test
    func `concurrent writers serialize: a read-modify-write counter has no lost updates`() async throws {
        try await withTempDBPath { path in
            let db = try AsyncDatabase(path: path)
            defer { Task { await db.close() } }

            let counterKey = key(0xFFFF)
            try await db.put(counterKey, bytes(0))

            // Each task performs a full read-modify-write of the SAME counter inside
            // one write transaction. The increment reads the counter through the
            // write txn's own uncommitted view and writes back +1. If writes did not
            // serialize, increments would race and updates would be lost. Because
            // every write funnels through the one writer (actor + single worker +
            // engine WriterThread), the final value must equal the increment count
            // exactly.
            let writers = 50
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0 ..< writers {
                    group.addTask {
                        try await db.write { txn throws(DBError) in
                            let current = try txn.get(counterKey).flatMap(uint64) ?? 0
                            try txn.put(counterKey, bytes(current + 1))
                        }
                    }
                }
                try await group.waitForAll()
            }

            let final = try await db.get(counterKey).flatMap(uint64)
            #expect(final == UInt64(writers))
        }
    }

    @Test
    func `writes apply in submission order from a single task`() async throws {
        try await withTempDBPath { path in
            let db = try AsyncDatabase(path: path)
            defer { Task { await db.close() } }

            // Sequential awaits from one task: each completes before the next is
            // submitted, so the final value is deterministic regardless of the
            // funnel. This pins the happy-path ordering contract.
            for i in 1 ... 20 {
                try await db.put(key(0), bytes(UInt64(i)))
            }
            #expect(try await db.get(key(0)).flatMap(uint64) == 20)
        }
    }

    @Test
    func `a throwing write rolls back and persists nothing`() async throws {
        try await withTempDBPath { path in
            let db = try AsyncDatabase(path: path)
            defer { Task { await db.close() } }

            try await db.put(key(1), bytes(1))

            // The write mutates, then throws a DBError; the engine must discard the
            // mutation (atomic transaction: nothing is persisted on a thrown error).
            await #expect(throws: DBError.self) {
                try await db.write { txn throws(DBError) in
                    try txn.put(key(1), bytes(777))
                    try txn.put(key(2), bytes(888))
                    throw DBError.txnClosed  // any DBError aborts the transaction
                }
            }

            // The pre-write value survives; neither mutation from the aborted txn
            // is visible.
            #expect(try await db.get(key(1)).flatMap(uint64) == 1)
            #expect(try await db.get(key(2)) == nil)
        }
    }

    // MARK: - Cancellation

    @Test
    func `a read on an already-cancelled task throws before dispatch`() async throws {
        try await withTempDBPath { path in
            let db = try AsyncDatabase(path: path)
            defer { Task { await db.close() } }
            try await db.put(key(1), bytes(1))

            let task = Task {
                // Cancel self before the read is reached.
                withUnsafeCurrentTask { $0?.cancel() }
                return try await db.read { txn throws(DBError) in try txn.get(key(1)) }
            }
            await #expect(throws: CancellationError.self) {
                _ = try await task.value
            }
        }
    }

    // MARK: - Adoption

    @Test
    func `adopting an open handle shares the same data`() async throws {
        try await withTempDBPath { path in
            let handle = try Database.open(at: path)
            let db = AsyncDatabase(adopting: handle)
            defer { Task { await db.close() } }

            try await db.put(key(3), bytes(30))
            // Read straight from the underlying handle synchronously: the façade
            // wrote through the very same `Database`.
            let direct = try handle.read { txn throws(DBError) in try txn.get(key(3)) }
            #expect(direct.flatMap(uint64) == 30)
        }
    }
}
