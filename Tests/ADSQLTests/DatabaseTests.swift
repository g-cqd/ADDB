import ADFIO
import ADSQLModel
import Dispatch
import Synchronization
import Testing

@_spi(ADDBEngine) @testable import ADDBCore
@_spi(ADDBEngine) @testable import ADDBExec
@testable import ADDBTestSupport
@testable import ADSQL

struct DatabaseAPITests {
    @Test func openWriteReadReopen() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = dir.file("api.adsql")

        do {
            let db = try Database.open(at: path)
            try db.writeSync { (txn) throws(DBError) in
                try txn.put(Array("alpha".utf8), Array("1".utf8))
                try txn.put(Array("beta".utf8), [UInt8](repeating: 7, count: 30_000))  // overflow
                try txn.delete(Array("never".utf8))
            }
            #expect(db.generation == 1)
            #expect(db.count == 2)

            let snapshot = try db.read { (txn) throws(DBError) in
                (
                    alpha: try txn.get(Array("alpha".utf8)),
                    betaCount: try txn.get(Array("beta".utf8))?.count,
                    gamma: try txn.get(Array("gamma".utf8)),
                    hasAlpha: try txn.contains(Array("alpha".utf8))
                )
            }
            #expect(snapshot.alpha == Array("1".utf8))
            #expect(snapshot.betaCount == 30_000)
            #expect(snapshot.gamma == nil)
            #expect(snapshot.hasAlpha)
            db.close()
        }

        let db = try Database.open(at: path)
        defer { db.close() }
        #expect(db.generation == 1)
        let alpha = try db.read { (txn) throws(DBError) in try txn.get(Array("alpha".utf8)) }
        #expect(alpha == Array("1".utf8))
    }

    @Test func zeroCopySpansAndCursor() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("span.adsql"))
        defer { db.close() }
        try db.writeSync { (txn) throws(DBError) in
            for i in 0 ..< 50 {
                try txn.put(
                    Array("z\(String(repeating: "0", count: 2 - String(i).count))\(i)".utf8), Array("v\(i)".utf8))
            }
        }
        let probes = try db.read { (txn) throws(DBError) in
            // RawSpan access, no copies for inline values.
            let length = try txn.withValue(forKey: Array("z07".utf8)) { span in
                span?.byteCount ?? -1
            }
            let missing = try txn.withValue(forKey: Array("nope".utf8)) { span in
                span == nil
            }
            // Scoped cursor: ordered first/last.
            let bounds: ([UInt8]?, [UInt8]?) = try txn.withCursor { (cursor) throws(DBError) in
                _ = try cursor.move(to: .first)
                let first = try cursor.currentKey()
                _ = try cursor.move(to: .last)
                let last = try cursor.currentKey()
                return (first, last)
            }
            return (length: length, missing: missing, bounds: bounds)
        }
        #expect(probes.length == 2)
        #expect(probes.missing)
        #expect(probes.bounds.0 == Array("z00".utf8))
        #expect(probes.bounds.1 == Array("z49".utf8))
    }

    @Test func rollbackOnThrowPersistsNothing() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("rollback.adsql"))
        defer { db.close() }
        try db.writeSync { (txn) throws(DBError) in
            try txn.put(Array("keep".utf8), [1])
        }
        #expect(throws: DBError.keyEmpty) {
            try db.writeSync { (txn) throws(DBError) in
                try txn.put(Array("ghost".utf8), [2])
                try txn.put([], [3])  // throws → whole txn discarded
            }
        }
        #expect(db.generation == 1)
        let after = try db.read { (txn) throws(DBError) in
            (ghost: try txn.get(Array("ghost".utf8)), keep: try txn.get(Array("keep".utf8)))
        }
        #expect(after.ghost == nil)
        #expect(after.keep == [1])
    }

    @Test func emptyWriteIsElided() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("elide.adsql"))
        defer { db.close() }
        try db.writeSync { (txn) throws(DBError) in try txn.put([1], [1]) }
        let before = db.generation
        let probed = try db.writeSync { (txn) throws(DBError) in
            let miss = try txn.get([9, 9])  // reads only
            try txn.delete([42])  // miss: no mutation
            return miss == nil
        }
        #expect(probed)
        #expect(db.generation == before)
    }

    @Test func closedDatabaseRejectsWork() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("closed.adsql"))
        db.close()
        #expect(throws: DBError.databaseClosed) {
            try db.read { _ in }
        }
        #expect(throws: DBError.databaseClosed) {
            try db.writeSync { (txn) throws(DBError) in try txn.put([1], [1]) }
        }
    }

    @Test func readOnlyHandleRejectsWrites() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = dir.file("ro.adsql")
        do {
            let db = try Database.open(at: path)
            try db.writeSync { (txn) throws(DBError) in try txn.put([5], [5]) }
            db.close()
        }
        var options = DatabaseOptions()
        options.readOnly = true
        let ro = try Database.open(at: path, options: options)
        defer { ro.close() }
        let roValue = try ro.read { (txn) throws(DBError) in try txn.get([5]) }
        #expect(roValue == [5])
        #expect(throws: DBError.readOnlyDatabase) {
            try ro.writeSync { (txn) throws(DBError) in try txn.put([6], [6]) }
        }
    }
}

@Suite(.serialized)
struct DatabaseConcurrencyTests {
    /// The headline invariant: a writer continuously rewrites N keys with a
    /// batch stamp; every reader snapshot must observe ALL keys carrying the
    /// SAME stamp (atomicity + isolation), never a mix.
    @Test func snapshotConsistencyUnderChurn() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("stress.adsql"))
        defer { db.close() }

        let keyCount = 64
        let keys = (0 ..< keyCount).map { Array("sc-\($0)".utf8) }
        try db.writeSync { (txn) throws(DBError) in
            for key in keys { try txn.put(key, stampValue(0)) }
        }

        let group = DispatchGroup()
        let stopped = Mutex(false)
        let readerFailures = Mutex<[String]>([])

        // 12 readers hammering snapshots.
        for _ in 0 ..< 12 {
            DispatchQueue.global()
                .async(group: group) {
                    while !stopped.withLock({ $0 }) {
                        do {
                            try db.read { (txn) throws(DBError) in
                                var stamps = Set<UInt64>()
                                for key in keys {
                                    guard let value = try txn.get(key), let stamp = readStamp(value) else {
                                        readerFailures.withLock { $0.append("missing key/stamp") }
                                        return
                                    }
                                    stamps.insert(stamp)
                                }
                                if stamps.count != 1 {
                                    readerFailures.withLock { $0.append("mixed stamps \(stamps.sorted())") }
                                }
                            }
                        } catch {
                            readerFailures.withLock { $0.append("read threw: \(error)") }
                            return
                        }
                    }
                }
        }

        // One writer: 150 full-batch rewrites.
        var writerError: (any Error)?
        for stamp in UInt64(1) ... 150 {
            do {
                try db.writeSync { (txn) throws(DBError) in
                    for key in keys { try txn.put(key, stampValue(stamp)) }
                }
            } catch {
                writerError = error
                break
            }
        }
        stopped.withLock { $0 = true }
        group.wait()

        #expect(writerError == nil)
        let failures = readerFailures.withLock { $0 }
        #expect(failures.isEmpty, "\(failures.prefix(3))")
        #expect(db.generation == 151)

        // Post-churn structural health.
        let channel = try FileChannel(path: dir.file("stress.adsql"), mode: .readOnly)
        defer { channel.close() }
        let meta = try Recovery.openOrCreate(channel: channel, createIfMissing: false)
        let pager = try Pager(channel: channel, maxMapSize: 1 << 30)
        _ = try KernelOps.checkLiveness(CommittedResolver(source: pager), meta)
    }

    /// Long-lived readers pin their generation's pages while newer commits
    /// proceed — and reclamation resumes once they end.
    @Test func pinnedReaderSeesFrozenSnapshot() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("pin.adsql"))
        defer { db.close() }
        try db.writeSync { (txn) throws(DBError) in try txn.put(Array("k".utf8), Array("old".utf8)) }

        let readerEntered = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)
        struct Observation: Sendable {
            var value: [UInt8]?
            var gen: UInt64 = 0
        }
        let observation = Mutex(Observation())

        let group = DispatchGroup()
        DispatchQueue.global()
            .async(group: group) {
                try? db.read { (txn) throws(DBError) in
                    readerEntered.signal()
                    // Hold the snapshot while the writer commits 30 generations.
                    writerDone.wait()
                    let value = try txn.get(Array("k".utf8))
                    let generation = txn.generation
                    observation.withLock { $0 = Observation(value: value, gen: generation) }
                }
            }

        readerEntered.wait()
        for i in 0 ..< 30 {
            try db.writeSync { (txn) throws(DBError) in
                try txn.put(Array("k".utf8), Array("new-\(i)".utf8))
                try txn.put(Array("filler-\(i)".utf8), [UInt8](repeating: 1, count: 500))
            }
        }
        writerDone.signal()
        group.wait()

        let observed = observation.withLock { $0 }
        #expect(observed.value == Array("old".utf8))
        #expect(observed.gen == 1)
        let current = try db.read { (txn) throws(DBError) in try txn.get(Array("k".utf8)) }
        #expect(current == Array("new-29".utf8))
    }

    /// FIX #8 (striped reader registration) stress: many concurrent striped readers
    /// hammer SQL snapshots while one writer runs a heavy insert/update/delete loop
    /// with a periodic integrity checkpoint. Each committed generation `s` leaves the
    /// table in a state that is a PURE FUNCTION `f(s)` — the live ids are exactly
    /// `{ id : id % 8 != s % 8 }`, every row stamped `s` — so ANY atomic snapshot a
    /// reader observes must equal `f(s)` for the single stamp `s` it sees. That `f(s)`
    /// is the serial oracle (a serial, reader-free execution reaches the same pure
    /// state). A torn snapshot (mixed stamps, a wrong id set, or a page the writer
    /// reclaimed out from under the reader) makes the snapshot ≠ `f(s)` or throws — so
    /// this asserts the reclamation lower-bound invariant holds under the striped
    /// registration path. `verifyIntegrity` is the checkpoint: it re-reads as a fresh
    /// snapshot and validates page liveness, the direct signal of an over-eager reclaim.
    @Test func stripedReadersStayConsistentUnderChurnAndMatchSerialOracle() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        // `.none` durability: reader registration and page reclamation are independent
        // of fsync, so skip it to fit far more generations (more race exposure) per second.
        let db = try Database.open(
            at: dir.file("striped-stress.adsql"), options: DatabaseOptions(durability: .none))
        defer { db.close() }
        try db.writeSync { (txn) throws(DBError) in
            try txn.createTable(
                TableDefinition(
                    "t",
                    columns: [
                        ColumnDefinition("id", .integer, notNull: true),
                        ColumnDefinition("stamp", .integer, notNull: true),
                        ColumnDefinition("payload", .text, notNull: true)
                    ],
                    primaryKey: .rowidAlias(column: "id", autoincrement: true)))
        }

        let idCount = 64
        let generations = 300
        let filler = String(repeating: "x", count: 220)  // ~240-byte rows → real page churn
        func residue(_ s: Int) -> Int { ((s % 8) + 8) % 8 }
        func liveIDs(_ s: Int) -> [Int] { (0 ..< idCount).filter { $0 % 8 != residue(s) } }
        func payload(_ id: Int) -> String { "row-\(id)-\(filler)" }  // constant per id

        // Precompute the serial oracle f(s) (id → payload) for every stamp, so the
        // @Sendable reader closures capture only a plain Sendable value, never a local
        // function.
        let oracles: [[Int: String]] = (0 ... generations)
            .map { s in
                Dictionary(uniqueKeysWithValues: liveIDs(s).map { ($0, payload($0)) })
            }

        // Seed f(0).
        try db.transaction { (txn) throws(DBError) in
            for id in liveIDs(0) {
                try txn.run("INSERT INTO t(id, stamp, payload) VALUES(\(id), 0, '\(payload(id))')")
            }
        }

        let stopped = Mutex(false)
        let failures = Mutex<[String]>([])
        let snapshotCount = Atomic<UInt64>(0)
        let group = DispatchGroup()

        let readerCount = 16
        for _ in 0 ..< readerCount {
            DispatchQueue.global()
                .async(group: group) {
                    guard let select = try? db.prepare("SELECT id, stamp, payload FROM t") else {
                        failures.withLock { $0.append("prepare failed") }
                        return
                    }
                    while !stopped.withLock({ $0 }) {
                        do {
                            let rows = try select.all().map(\.values)
                            snapshotCount.wrappingAdd(1, ordering: .relaxed)
                            var stamp: Int64?
                            var content: [Int: String] = [:]
                            for row in rows {
                                guard case .integer(let id) = row[0], case .integer(let st) = row[1],
                                    case .text(let pay) = row[2]
                                else {
                                    failures.withLock { $0.append("bad row shape \(row)") }
                                    return
                                }
                                if let stamp, stamp != st {
                                    failures.withLock { $0.append("torn snapshot: mixed stamps") }
                                    return
                                }
                                stamp = st
                                content[Int(id)] = pay
                            }
                            let s = Int(stamp ?? 0)
                            guard s >= 0, s <= generations else {
                                failures.withLock { $0.append("stamp \(s) out of range") }
                                return
                            }
                            // The snapshot must EXACTLY equal the serial oracle f(s):
                            // same id set (no reclaimed/duplicated row) and same payloads.
                            if content != oracles[s] {
                                failures.withLock {
                                    $0.append("snapshot at stamp \(s) != oracle (\(rows.count) rows)")
                                }
                                return
                            }
                        } catch {
                            failures.withLock { $0.append("read threw: \(error)") }
                            return
                        }
                    }
                }
        }

        // Writer: `generations` atomic insert/update/delete transactions, each leaving
        // the table at exactly f(s); a periodic integrity checkpoint runs as a reader.
        var writerError: (any Error)?
        do {
            for s in 1 ... generations {
                let dead = Array(stride(from: residue(s), to: idCount, by: 8))  // id % 8 == s % 8
                let born = Array(stride(from: residue(s - 1), to: idCount, by: 8))  // id % 8 == (s-1) % 8
                try db.transaction { (txn) throws(DBError) in
                    if !dead.isEmpty {
                        try txn.run(
                            "DELETE FROM t WHERE id IN (\(dead.map(String.init).joined(separator: ",")))")
                    }
                    for id in born {
                        try txn.run("INSERT INTO t(id, stamp, payload) VALUES(\(id), \(s), '\(payload(id))')")
                    }
                    try txn.run("UPDATE t SET stamp = \(s)")
                }
                if s % 25 == 0 { _ = try db.verifyIntegrity() }  // checkpoint
            }
        } catch {
            writerError = error
        }
        stopped.withLock { $0 = true }
        group.wait()

        #expect(writerError == nil, "writer failed: \(String(describing: writerError))")
        let seen = failures.withLock { $0 }
        #expect(seen.isEmpty, "\(seen.prefix(3))")

        // Serial oracle for the FINAL state: exactly f(generations).
        let finalRows = try db.prepare("SELECT id, stamp, payload FROM t").all().map(\.values)
        var finalContent: [Int: String] = [:]
        var finalStampsUniform = true
        for row in finalRows {
            guard case .integer(let id) = row[0], case .integer(let st) = row[1], case .text(let pay) = row[2]
            else {
                Issue.record("bad final row shape")
                continue
            }
            if st != Int64(generations) { finalStampsUniform = false }
            finalContent[Int(id)] = pay
        }
        #expect(finalStampsUniform, "final rows not all stamped \(generations)")
        #expect(finalContent == oracles[generations], "final state != serial oracle f(\(generations))")

        // The readers actually ran many concurrent snapshots (race exposure sanity).
        let total = snapshotCount.load(ordering: .relaxed)
        #expect(total > UInt64(generations), "readers barely ran (\(total) snapshots)")

        _ = try db.verifyIntegrity()
    }
}

private func stampValue(_ stamp: UInt64) -> [UInt8] {
    var value = [UInt8](repeating: 0, count: 64)
    withUnsafeBytes(of: stamp.littleEndian) { value.replaceSubrange(0 ..< 8, with: $0) }
    return value
}

private func readStamp(_ value: [UInt8]) -> UInt64? {
    guard value.count >= 8 else { return nil }
    return value.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
}
