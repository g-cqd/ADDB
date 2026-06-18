import Foundation
import Testing

// White-box access to the engine: `@testable` reaches `internal` symbols (SwiftPM
// builds the root package's `ADDBCore` with `-enable-testing` for its own tests), and
// `@_spi(ADDBEngine)` reaches the broad engine surface (cursors, transactions) that the
// SQL layer also drives. These characterization tests pin the engine's externally
// observable behavior so the ADDB package is verifiable on its own — the deep coverage
// otherwise lives in the sibling ADSQL package's integration suite.
@_spi(ADDBEngine) @testable import ADDBCore

@Suite("ADDB engine characterization")
struct ADDBEngineCharacterizationTests {
    /// A unique scratch path; the engine owns the file plus its `-wal`/`-shm`/`-lock`
    /// siblings, so the helper removes all of them.
    private func withTempPath(_ body: (String) throws -> Void) rethrows {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("addb-\(UUID().uuidString).db").path
        defer {
            for suffix in ["", "-wal", "-shm", "-lock"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        try body(path)
    }

    private func key(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test("open creates a database with the requested path")
    func openCreates() throws {
        try withTempPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            #expect(db.path == path)
        }
    }

    @Test("put then get round-trips the value")
    func putGetRoundTrip() throws {
        try withTempPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            try db.writeSync { (txn) throws(DBError) in
                try txn.put(key("alpha"), key("one"))
            }
            let value = try db.read { (txn) throws(DBError) in try txn.get(key("alpha")) }
            #expect(value.map { String(decoding: $0, as: UTF8.self) } == "one")
        }
    }

    @Test("delete reports prior existence and removes the key")
    func deleteSemantics() throws {
        try withTempPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            try db.writeSync { (txn) throws(DBError) in try txn.put(key("k"), key("v")) }
            let existed = try db.writeSync { (txn) throws(DBError) in try txn.delete(key("k")) }
            let missing = try db.writeSync { (txn) throws(DBError) in try txn.delete(key("absent")) }
            let after = try db.read { (txn) throws(DBError) in try txn.get(key("k")) }
            #expect(existed == true)
            #expect(missing == false)
            #expect(after == nil)
        }
    }

    @Test("committed data survives a reopen")
    func persistenceAcrossReopen() throws {
        try withTempPath { path in
            let writer = try Database.open(at: path)
            try writer.writeSync { (txn) throws(DBError) in try txn.put(key("durable"), key("yes")) }
            writer.close()

            let reader = try Database.open(at: path, options: DatabaseOptions(readOnly: true))
            defer { reader.close() }
            let value = try reader.read { (txn) throws(DBError) in try txn.get(key("durable")) }
            #expect(value.map { String(decoding: $0, as: UTF8.self) } == "yes")
        }
    }

    @Test("count reflects the number of stored keys")
    func countTracksKeys() throws {
        try withTempPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            try db.writeSync { (txn) throws(DBError) in
                for i in 0 ..< 16 { try txn.put(key("key-\(i)"), key("value-\(i)")) }
            }
            #expect(db.count == 16)
        }
    }

    @Test("a write advances the generation")
    func writeAdvancesGeneration() throws {
        try withTempPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            let before = db.generation
            try db.writeSync { (txn) throws(DBError) in try txn.put(key("g"), key("1")) }
            #expect(db.generation > before)
        }
    }

    @Test("a forward cursor scan yields keys in ascending order")
    func cursorScanIsOrdered() throws {
        try withTempPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            try db.writeSync { (txn) throws(DBError) in
                for i in [3, 1, 2, 0] { try txn.put(key("k\(i)"), key("v\(i)")) }
            }
            let keys = try db.read { (txn) throws(DBError) -> [String] in
                var out: [String] = []
                try txn.withCursor { (cursor) throws(DBError) in
                    guard try cursor.move(to: .first) else { return }
                    repeat {
                        if let bytes = try cursor.withCurrent({ (rawKey, _) in Array(rawKey) }) {
                            out.append(String(decoding: bytes, as: UTF8.self))
                        }
                    } while try cursor.next()
                }
                return out
            }
            #expect(keys == ["k0", "k1", "k2", "k3"])
        }
    }

    @Test("integrity verification passes on a freshly written database")
    func integrityHolds() throws {
        try withTempPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            try db.writeSync { (txn) throws(DBError) in
                for i in 0 ..< 32 { try txn.put(key("row-\(i)"), key("payload-\(i)")) }
            }
            let report = try db.verifyIntegrity(deep: true)
            #expect(report.kvCount == 32)
        }
    }
}
