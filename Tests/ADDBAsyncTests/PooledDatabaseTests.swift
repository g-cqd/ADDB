import ADConcurrency
import ADDB
import ADSQLModel
import Foundation
import Testing

@testable import ADDBAsync

/// Characterizes the optional pooled read path: independent read-only handles
/// managed by ``ADConcurrency/ResourcePool``, fronted by ``PooledReadDatabase``.
/// Writes still go through ``AsyncDatabase``; the pool is read-only by design.
@Suite(.serialized)
struct PooledDatabaseTests {
    @Test
    func `PooledDatabase conforms to PooledResource and opens an existing file`() async throws {
        try await withTempDBPath { path in
            // Seed the file with a writable handle first (the pool opens read-only).
            let writer = try AsyncDatabase(path: path)
            try await writer.put(key(1), bytes(11))
            await writer.close()

            // A pool of independent read-only handles over the same file.
            let resource = PooledDatabase(path: path)
            #expect(resource != nil)
        }
    }

    @Test
    func `a non-existent path yields nil (read-only, createIfMissing: false)`() async throws {
        try await withTempDBPath { path in
            // Nothing was created at `path`, so the read-only open must fail.
            #expect(PooledDatabase(path: path) == nil)
            #expect(PooledReadDatabase(path: path, count: 2) == nil)
        }
    }

    @Test
    func `concurrent pooled reads all observe the seeded data`() async throws {
        try await withTempDBPath { path in
            let writer = try AsyncDatabase(path: path)
            let n: UInt64 = 128
            try await writer.write { txn throws(DBError) in
                for i in 0 ..< n { try txn.put(key(i), bytes(i &+ 1000)) }
            }
            await writer.close()

            guard let pool = PooledReadDatabase(path: path, count: 4) else {
                Issue.record("expected the read pool to open over a seeded file")
                return
            }
            defer { pool.shutdown() }
            #expect(pool.handleCount == 4)

            let readers = 40
            try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0 ..< readers {
                    group.addTask {
                        try await pool.read { txn throws(DBError) in
                            for i in 0 ..< n {
                                guard let raw = try txn.get(key(i)), uint64(raw) == i &+ 1000 else {
                                    return false
                                }
                            }
                            return true
                        }
                    }
                }
                for try await ok in group { #expect(ok) }
            }

            // The convenience point read works too.
            #expect(try await pool.get(key(0)).flatMap(uint64) == 1000)
        }
    }
}
