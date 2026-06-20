import ADSQLModel
// Deterministic, dependency-free engine characterization. Unlike the sibling
// `EngineCharacterizationTests` / `CorruptFileFuzzTests` / `CivilTimeTests` — all
// gated behind `#if canImport(ADTestKit)` (a DEV-only dependency resolved only under
// `ADDB_DEV=1`) and so compiling to NOTHING in the lean `ADDB_TESTING=1` build — this
// suite uses only Foundation + the in-package `withTempDBPath` helper. It therefore
// runs under the plain `ADDB_TESTING=1 swift test` invocation, giving the ADDB package
// its OWN deep storage-engine coverage so it is verifiable standalone. The deep
// coverage otherwise lives in the sibling ADSQL package's integration suite (the
// cross-package coupling this suite reduces).
//
// Inputs are hand-chosen (no SeededRNG / ByteMutator), so every case is fully
// reproducible and the build needs no test-only RNG. The white-box access mirrors the
// other suites exactly: `@testable` reaches `internal` symbols (SwiftPM builds
// `ADDBCore` with `-enable-testing` under `ADDB_TESTING=1`) and `@_spi(ADDBEngine)`
// reaches the broad engine surface (codecs, cursors, free-list, overflow, meta) that
// the SQL layer also drives.
import Foundation
import Testing

@_spi(ADDBEngine) @testable import ADDBCore

@Suite("ADDB storage-engine characterization")
struct StorageEngineCharacterizationTests {
    // MARK: - Helpers

    private func key(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func str(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    /// A value sized so a 16 KiB leaf holds only a handful of cells: the inline
    /// limit is `maxInlineCellSize` (4064), so `≈ maxInlineCellSize - 64` packs ~4
    /// cells per leaf. A few dozen such keys grow the main B+tree to depth ≥ 2 with a
    /// small entry count — which is exactly what exercises branch pages, separators,
    /// and the multi-level split path while keeping each test cheap.
    private func fatInlineValue(seed: UInt8) -> [UInt8] {
        [UInt8](repeating: seed, count: Format.maxInlineCellSize - 64)
    }

    /// Walks the whole main tree in order through the SPI cursor and returns the
    /// keys as strings — the externally observable "what's stored, in order" oracle.
    private func orderedKeys(_ db: Database) throws -> [String] {
        try db.read { (txn) throws(DBError) -> [String] in
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
    }

    // MARK: - B+tree: insert / split / delete key ordering

    @Test("inserting keys in scrambled order yields a fully ordered B+tree")
    func insertScrambledKeysOrders() throws {
        try withTempDBPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            // A deliberately scrambled permutation of 0..<40, inserted small-valued so
            // they share leaves; the tree must read back in strict ascending key order.
            let order = [
                17, 3, 28, 9, 0, 35, 12, 21, 6, 31, 14, 39, 1, 24, 8, 33, 19, 5,
                27, 11, 38, 2, 22, 16, 30, 7, 36, 13, 25, 4, 29, 10, 37, 18, 23,
                15, 34, 20, 32, 26
            ]
            try db.writeSync { (txn) throws(DBError) in
                for i in order { try txn.put(key(String(format: "k%03d", i)), key("v\(i)")) }
            }
            let expected = (0 ..< 40).map { String(format: "k%03d", $0) }
            #expect(try orderedKeys(db) == expected)
            #expect(db.count == 40)
        }
    }

    @Test("near-page-sized values force leaf splits and grow the tree past one level")
    func largeValuesForceSplitsAndGrowDepth() throws {
        try withTempDBPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            // 24 fat values, each ~4000 bytes: a 16 KiB leaf holds ~4, so ~6 leaves and
            // at least one branch level — the split machinery must keep the tree ordered.
            let n = 24
            try db.writeSync { (txn) throws(DBError) in
                for i in 0 ..< n {
                    try txn.put(key(String(format: "row%02d", i)), fatInlineValue(seed: UInt8(i)))
                }
            }
            let report = try db.verifyIntegrity()
            #expect(report.kvCount == UInt64(n))
            // The split grew the tree beyond a single leaf (depth ≥ 2 means ≥ 1 branch).
            #expect(report.treeDepth >= 2)
            #expect(report.mainTreePages >= 2)
            // Order survives the splits, and every value round-trips byte-exactly.
            let expected = (0 ..< n).map { String(format: "row%02d", $0) }
            #expect(try orderedKeys(db) == expected)
            try db.read { (txn) throws(DBError) in
                for i in 0 ..< n {
                    let v = try txn.get(key(String(format: "row%02d", i)))
                    #expect(v == fatInlineValue(seed: UInt8(i)))
                }
            }
        }
    }

    @Test("deleting half the keys preserves order and integrity of the rest")
    func deleteHalfPreservesOrderAndIntegrity() throws {
        try withTempDBPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            // Build a multi-level tree, then delete every even key. The survivors must
            // stay ordered and the tree must remain structurally sound (no leaked or
            // double-claimed pages, counts consistent).
            let n = 30
            try db.writeSync { (txn) throws(DBError) in
                for i in 0 ..< n {
                    try txn.put(key(String(format: "d%02d", i)), fatInlineValue(seed: UInt8(i)))
                }
            }
            try db.writeSync { (txn) throws(DBError) in
                for i in stride(from: 0, to: n, by: 2) {
                    let existed = try txn.delete(key(String(format: "d%02d", i)))
                    #expect(existed)
                }
            }
            let expected = stride(from: 1, to: n, by: 2).map { String(format: "d%02d", $0) }
            #expect(try orderedKeys(db) == expected)
            #expect(db.count == UInt64(expected.count))
            let report = try db.verifyIntegrity()
            #expect(report.kvCount == UInt64(expected.count))
            // The odd survivors still read back exactly.
            try db.read { (txn) throws(DBError) in
                for i in stride(from: 1, to: n, by: 2) {
                    #expect(try txn.get(key(String(format: "d%02d", i))) == fatInlineValue(seed: UInt8(i)))
                }
                // A deleted key is gone.
                #expect(try txn.get(key("d00")) == nil)
            }
        }
    }

    @Test("deleting every key empties the tree back to a zero root")
    func deleteAllEmptiesTree() throws {
        try withTempDBPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            let n = 20
            try db.writeSync { (txn) throws(DBError) in
                for i in 0 ..< n { try txn.put(key(String(format: "z%02d", i)), key("v\(i)")) }
            }
            try db.writeSync { (txn) throws(DBError) in
                for i in 0 ..< n { #expect(try txn.delete(key(String(format: "z%02d", i)))) }
            }
            #expect(db.count == 0)
            #expect(try orderedKeys(db).isEmpty)
            // An empty tree is still a valid, fully-accounted database.
            let report = try db.verifyIntegrity()
            #expect(report.kvCount == 0)
        }
    }

    // MARK: - Freelist: page reuse after deletes

    @Test("freed pages are reused so the file does not grow unboundedly")
    func freelistReusesPagesAfterDeletes() throws {
        try withTempDBPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            // Seed a tree spanning several pages.
            let n = 24
            func payload(_ i: Int) -> [UInt8] { fatInlineValue(seed: UInt8(i & 0xFF)) }
            try db.writeSync { (txn) throws(DBError) in
                for i in 0 ..< n { try txn.put(key(String(format: "f%02d", i)), payload(i)) }
            }
            let pagesAfterSeed = try db.verifyIntegrity().pageCount

            // Delete everything, then drive several no-op-ish write cycles. There is no
            // live reader, so each commit lets the previous commit's freed pages cross
            // the one-generation reclaim lag (`Meta.reclaimLimit`) and land in the
            // allocator pool. After they are pooled, re-inserting reuses them instead of
            // extending the high-water mark.
            try db.writeSync { (txn) throws(DBError) in
                for i in 0 ..< n { _ = try txn.delete(key(String(format: "f%02d", i))) }
            }
            // A couple of tiny churn commits advance the generation so the deletes'
            // freed pages become harvestable (gen lag + "no reader below limit").
            for tick in 0 ..< 3 {
                try db.writeSync { (txn) throws(DBError) in
                    try txn.put(key("tick"), key("\(tick)"))
                }
            }
            // Some pages must now be on the free list OR already reclaimed into the pool.
            let afterDeletePages = try db.verifyIntegrity().pageCount

            // Re-insert the same shape. If freed pages are genuinely reused, the file's
            // high-water page count must NOT climb to roughly twice the seed size — it
            // should land at or near the post-seed footprint.
            try db.writeSync { (txn) throws(DBError) in
                for i in 0 ..< n { try txn.put(key(String(format: "g%02d", i)), payload(i)) }
            }
            let pagesAfterReinsert = try db.verifyIntegrity().pageCount

            // The decisive check: reusing freed pages keeps the footprint bounded. A
            // non-reusing engine would need a fresh page per re-inserted cell, pushing
            // the count to ≈ seed + reinsert. We assert it stays well under seed * 2.
            #expect(pagesAfterReinsert < pagesAfterSeed * 2)
            #expect(try db.verifyIntegrity().kvCount == UInt64(n + 1))  // n g-keys + "tick"
            // Sanity that the churn actually freed pages at some point (the file did not
            // simply keep every page live across the delete).
            #expect(afterDeletePages <= pagesAfterReinsert)
        }
    }

    @Test("the free tree lists freed pages and integrity accounts for every one")
    func freelistInspectionAccountsForFreedPages() throws {
        try withTempDBPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            try db.writeSync { (txn) throws(DBError) in
                for i in 0 ..< 16 { try txn.put(key(String(format: "p%02d", i)), fatInlineValue(seed: UInt8(i))) }
            }
            // Delete a chunk to retire pages into the free tree, then advance a tick so
            // the serialized free entries are committed and visible to a reader.
            try db.writeSync { (txn) throws(DBError) in
                for i in 0 ..< 8 { _ = try txn.delete(key(String(format: "p%02d", i))) }
            }
            try db.writeSync { (txn) throws(DBError) in try txn.put(key("after"), key("x")) }

            // verifyIntegrity proves the page-liveness invariant globally: every page in
            // [0, pageCount) is claimed exactly once across {metas} ∪ main ∪ free-tree ∪
            // free-listed, pairwise disjoint. That it returns at all means the free-listed
            // pages are correctly bookkept (no leak, no double-use).
            let report = try db.verifyIntegrity()
            #expect(report.pageCount > Format.firstDataPage)

            // Cross-check the free-tree inspection API against the integrity report's
            // free-listed count: the two independent paths must agree.
            let listed = try db.read { (txn) throws(DBError) -> [(gen: UInt64, page: UInt64)] in
                try FreeList.allListedPages(resolver: txn.resolver, tree: txn.meta.freeTree)
            }
            #expect(listed.count == report.freeListedPages)
            // Free-listed page numbers are unique (no page listed twice).
            #expect(Set(listed.map { $0.page }).count == listed.count)
        }
    }

    // MARK: - Codec round-trips (pure functions, no database)

    @Test("RecordCodec round-trips every storage class")
    func recordCodecRoundTrips() throws {
        let rows: [[Value]] = [
            [],
            [.null],
            [.integer(0), .integer(1), .integer(-1)],
            [.integer(Int64.min), .integer(Int64.max)],
            [.real(0.0), .real(-0.0), .real(3.141592653589793), .real(-2.5)],
            [.real(.infinity), .real(-.infinity)],
            [.text(""), .text("hello"), .text("héllo · 世界 · 🌍")],
            [.blob([]), .blob([0x00, 0xFF, 0x00, 0x01, 0x7F, 0x80])],
            [.null, .integer(42), .real(1.5), .text("mix"), .blob([1, 2, 3])]
        ]
        for row in rows {
            let encoded = RecordCodec.encode(row)
            let decoded = try encoded.withUnsafeBytesThrowing { (raw) throws(DBError) in
                try RecordCodec.decode(raw)
            }
            #expect(decoded == row, "record round-trip failed for \(row)")
        }
    }

    @Test("KeyCodec is order-preserving and round-trips non-NOCASE fields")
    func keyCodecOrderAndRoundTrip() throws {
        // Order-preservation across storage classes: NULL < INTEGER < REAL < TEXT < BLOB,
        // and within a class the encoded memcmp order matches the typed order.
        let ascending: [Value] = [
            .null,
            .integer(-5), .integer(0), .integer(7),
            .real(-1.0), .real(0.0), .real(2.0),
            .text("aaa"), .text("aab"), .text("b"),
            .blob([0x00]), .blob([0x01]), .blob([0x01, 0x00])
        ]
        let encoded = try ascending.map { v in try KeyCodec.encode([v], collations: [.binary]) }
        for i in 1 ..< encoded.count {
            #expect(
                lexicographicallyLess(encoded[i - 1], encoded[i]),
                "encoded keys not strictly ascending at \(i): \(ascending[i - 1]) vs \(ascending[i])")
        }

        // Round-trip the losslessly-decodable classes (NOCASE folds, so it is excluded
        // by contract; the encoder normalizes -0.0 → +0.0, mirrored on decode).
        let roundTrippable: [Value] = [
            .null, .integer(-123_456_789), .integer(Int64.max),
            .real(3.5), .real(-7.25), .text("round trip"), .blob([0x00, 0xFF, 0x10])
        ]
        for v in roundTrippable {
            let bytes = try KeyCodec.encode([v], collations: [.binary])
            let back = try bytes.withUnsafeBytesThrowing { (raw) throws(DBError) in
                try KeyCodec.decode(raw, columns: 1)
            }
            #expect(back == [normalizedForKey(v)], "key round-trip failed for \(v)")
        }
    }

    @Test("Meta encodes into a page and decodes back identically with a valid checksum")
    func metaPageCodecRoundTrips() throws {
        let meta = Meta(
            generation: 42, rootPage: 7, freeRootPage: 9, pageCount: 128,
            kvCount: 1000, treeDepth: 3, flags: 0, freeDepth: 2, freeEntryCount: 5)
        let buf = PageBuf()
        buf.withMutableBytes { page in meta.encode(into: &page, pageNo: 0) }

        let decoded: Meta.DecodeResult = unsafe Meta.decode(from: buf.readOnly, pageNo: 0)
        guard case .valid(let back) = decoded else {
            Issue.record("expected a valid meta decode, got \(decoded)")
            return
        }
        #expect(back == meta)

        // Decoding the same bytes under the WRONG page number must fail the checksum
        // (the digest is seeded with the page number — a meta written for page 0 cannot
        // masquerade as page 1).
        let wrongSeed = unsafe Meta.decode(from: buf.readOnly, pageNo: 1)
        #expect(wrongSeed == .corrupt)
    }

    @Test("page checksums verify when intact and fail on a single flipped byte")
    func pageChecksumDetectsTampering() throws {
        let buf = PageBuf()
        // Build a plausible leaf page body, then stamp its checksum.
        buf.withMutableBytes { page in
            PageHeader.initialize(&page, type: .leaf)
            PageHeader.setCellCount(&page, 3)
            PageHeader.stampChecksum(&page, pageNo: 5)
        }
        #expect(unsafe PageHeader.verifyChecksum(buf.readOnly, pageNo: 5))
        // Same bytes verified against a different page number must fail (seeded digest).
        #expect(unsafe !PageHeader.verifyChecksum(buf.readOnly, pageNo: 6))
        // Flip one payload byte (past the 8-byte checksum field): verification must fail.
        let tampered = unsafe PageBuf(copying: buf.readOnly)
        tampered.withMutableBytes { page in
            let current = page.withUnsafeBytes { (ro: UnsafeRawBufferPointer) in unsafe ro[64] }
            page.storeBytes(of: current ^ 0xFF, toByteOffset: 64, as: UInt8.self)
        }
        #expect(unsafe !PageHeader.verifyChecksum(tampered.readOnly, pageNo: 5))
    }

    // MARK: - Overflow pages for large values

    @Test("a value larger than the inline limit spills to an overflow chain and round-trips")
    func largeValueUsesOverflowAndRoundTrips() throws {
        try withTempDBPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            // A value well past `maxInlineCellSize` must spill to overflow. Pick a size
            // that spans MORE than one overflow page so the multi-page chain link is
            // exercised, and fill it with a position-dependent pattern so a mis-assembled
            // chain (wrong order / dropped page) is detected, not just a length check.
            let size = Format.overflowCapacity * 2 + 777
            var big = [UInt8](repeating: 0, count: size)
            for i in 0 ..< size { big[i] = UInt8((i &* 31 &+ 7) & 0xFF) }

            try db.writeSync { (txn) throws(DBError) in try txn.put(key("huge"), big) }

            // Read it back byte-exactly.
            let got = try db.read { (txn) throws(DBError) in try txn.get(key("huge")) }
            #expect(got == big)

            // Integrity must see overflow pages, and their count must match the codec's
            // own page arithmetic for this length.
            let report = try db.verifyIntegrity()
            #expect(report.overflowPages == Overflow.pageCount(forLength: size))
            #expect(report.overflowPages >= 3)  // 2 full pages + a tail = 3
        }
    }

    @Test("overwriting an overflow value with a small one reclaims the chain")
    func overwriteOverflowWithInlineReleasesChain() throws {
        try withTempDBPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            let size = Format.overflowCapacity + 100
            let big = [UInt8](repeating: 0xAB, count: size)
            try db.writeSync { (txn) throws(DBError) in try txn.put(key("k"), big) }
            #expect(try db.verifyIntegrity().overflowPages >= 2)

            // Replace with a tiny inline value; the old chain's pages must be released
            // (and eventually reusable). The new value round-trips and no overflow page
            // is reachable from the live tree any more.
            try db.writeSync { (txn) throws(DBError) in try txn.put(key("k"), key("small")) }
            let got = try db.read { (txn) throws(DBError) in try txn.get(key("k")) }
            #expect(got.map(str) == "small")
            #expect(try db.verifyIntegrity().overflowPages == 0)
        }
    }

    // MARK: - MVCC snapshot isolation

    @Test("a reader's open snapshot stays consistent across a concurrent writer commit")
    func readerSnapshotIsolatedFromConcurrentWriter() throws {
        try withTempDBPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            // Establish the baseline committed value the reader will pin.
            try db.writeSync { (txn) throws(DBError) in try txn.put(key("mvcc"), key("v1")) }

            // Inside ONE open read snapshot:
            //   1. observe the baseline,
            //   2. let a *concurrent* writer (on its own OS thread) commit a new value,
            //   3. re-read through the SAME snapshot — it must still see the old value.
            // The read closure borrows `ReadTxn` for its whole duration, and the snapshot
            // is pinned to the meta captured at `beginRead`; the writer runs on the
            // database's dedicated writer thread and never mutates committed pages, so the
            // reader's view cannot shift mid-flight.
            let writerDone = DispatchSemaphore(value: 0)
            try db.read { (txn) throws(DBError) in
                let before = try txn.get(key("mvcc"))
                #expect(before.map(str) == "v1")

                // Concurrent committing writer on a separate thread (NOT the cooperative
                // pool): `writeSync` blocks its caller on the internal writer thread, so it
                // must not run on this reader thread. It commits a brand-new generation.
                let writer = Thread {
                    try? db.writeSync { (wtxn) throws(DBError) in try wtxn.put(key("mvcc"), key("v2")) }
                    writerDone.signal()
                }
                writer.start()
                writerDone.wait()

                // Same snapshot, after the concurrent commit: still the old value.
                let after = try txn.get(key("mvcc"))
                #expect(after.map(str) == "v1", "reader's pinned snapshot must not observe the concurrent commit")
            }

            // A FRESH read opened after the writer committed sees the new value: the
            // commit was real, only invisible to the older snapshot.
            let fresh = try db.read { (txn) throws(DBError) in try txn.get(key("mvcc")) }
            #expect(fresh.map(str) == "v2")
        }
    }

    @Test("a committed write advances the generation while an old snapshot keeps its own")
    func snapshotGenerationIsStable() throws {
        try withTempDBPath { path in
            let db = try Database.open(at: path)
            defer { db.close() }
            try db.writeSync { (txn) throws(DBError) in try txn.put(key("g"), key("1")) }

            let pinnedGeneration = try db.read { (txn) throws(DBError) -> UInt64 in
                let snapGen = txn.generation
                // Commit again from this thread (the read body holds no lock the writer
                // needs); the snapshot's own `generation` is fixed at open time.
                try db.writeSync { (wtxn) throws(DBError) in try wtxn.put(key("g"), key("2")) }
                #expect(txn.generation == snapGen, "snapshot generation must be immutable")
                return snapGen
            }
            // The database's newest generation moved past the pinned snapshot.
            #expect(db.generation > pinnedGeneration)
        }
    }

    // MARK: - Durability / recovery (reopen after commit)

    @Test("committed key/value data survives close and reopen")
    func dataSurvivesReopen() throws {
        try withTempDBPath { path in
            let originalKeys = (0 ..< 24).map { String(format: "persist-%02d", $0) }
            do {
                let db = try Database.open(at: path)
                try db.writeSync { (txn) throws(DBError) in
                    for (i, k) in originalKeys.enumerated() {
                        try txn.put(key(k), fatInlineValue(seed: UInt8(i)))
                    }
                }
                db.close()
            }
            // Reopen a fresh handle on the same file: every value must be intact and the
            // tree fully ordered, with integrity holding on the recovered generation.
            let db = try Database.open(at: path)
            defer { db.close() }
            #expect(try orderedKeys(db) == originalKeys)
            try db.read { (txn) throws(DBError) in
                for (i, k) in originalKeys.enumerated() {
                    #expect(try txn.get(key(k)) == fatInlineValue(seed: UInt8(i)))
                }
            }
            #expect(try db.verifyIntegrity().kvCount == UInt64(originalKeys.count))
        }
    }

    @Test("the newest generation survives across multiple reopen cycles")
    func latestGenerationSurvivesMultipleReopens() throws {
        try withTempDBPath { path in
            // Three separate open→write→close cycles, each layering a new value. The
            // final reopen must reflect every committed generation, proving recovery
            // always lands on the newest checksum-valid meta.
            for round in 0 ..< 3 {
                let db = try Database.open(at: path)
                try db.writeSync { (txn) throws(DBError) in
                    try txn.put(key("round-\(round)"), key("value-\(round)"))
                    // Also overwrite a shared key each round so the latest value wins.
                    try txn.put(key("latest"), key("\(round)"))
                }
                db.close()
            }
            let db = try Database.open(at: path)
            defer { db.close() }
            try db.read { (txn) throws(DBError) in
                #expect(try txn.get(key("latest")).map(str) == "2")
                for round in 0 ..< 3 {
                    #expect(try txn.get(key("round-\(round)")).map(str) == "value-\(round)")
                }
            }
            #expect(db.generation >= 3)
        }
    }

    @Test("an overflow value survives a reopen with its chain intact")
    func overflowValueSurvivesReopen() throws {
        try withTempDBPath { path in
            let size = Format.overflowCapacity * 2 + 321
            var big = [UInt8](repeating: 0, count: size)
            for i in 0 ..< size { big[i] = UInt8((i &* 17 &+ 3) & 0xFF) }
            do {
                let db = try Database.open(at: path)
                try db.writeSync { (txn) throws(DBError) in try txn.put(key("ovf"), big) }
                db.close()
            }
            let db = try Database.open(at: path)
            defer { db.close() }
            #expect(try db.read { (txn) throws(DBError) in try txn.get(key("ovf")) } == big)
            #expect(try db.verifyIntegrity().overflowPages == Overflow.pageCount(forLength: size))
        }
    }

    // MARK: - Integrity verification rejects a corrupted page

    /// Byte offset of a committed node page's header field, for on-disk tampering.
    /// Pages 0 and 1 are the ping-pong metas; data pages start at page 2.
    private func nodeFieldOffset(pageNo: UInt64, fieldOffset: Int) -> UInt64 {
        pageNo * UInt64(Format.pageSize) + UInt64(fieldOffset)
    }

    @Test("a structurally corrupt node page is rejected by a read, never trapped")
    func corruptNodePageRejectedOnRead() throws {
        try withTempDBPath { path in
            do {
                let db = try Database.open(at: path)
                defer { db.close() }
                try db.writeSync { (txn) throws(DBError) in
                    for i in 0 ..< 8 { try txn.put(key("c\(i)"), key("v\(i)")) }
                }
            }
            // Corrupt the `cellAreaStart` (offset 12, u16) of every data page to 0xFFFF —
            // past the page end, so any leaf/branch violates the structural invariant.
            // The live root is one of them, so resolving it on read must throw a clean
            // `DBError`, not trap in `rebasing:` and not hand back an in-page-but-wrong
            // value. (Same vector the gated fuzz suite asserts, here as one deterministic
            // hand-crafted corruption needing no RNG.)
            let fh = try FileHandle(forUpdating: URL(fileURLWithPath: path))
            defer { try? fh.close() }
            let size = try fh.seekToEnd()
            var pageNo: UInt64 = Format.firstDataPage
            while (pageNo + 1) * UInt64(Format.pageSize) <= size {
                try fh.seek(toOffset: nodeFieldOffset(pageNo: pageNo, fieldOffset: PageHeader.Offset.cellAreaStart))
                try fh.write(contentsOf: Data([0xFF, 0xFF]))
                pageNo += 1
            }
            try fh.close()

            #expect(throws: DBError.self) {
                let db = try Database.open(at: path)
                defer { db.close() }
                _ = try db.read { (txn) throws(DBError) in try txn.get(key("c0")) }
            }
        }
    }

    @Test("verifyIntegrity with checksums rejects a page whose bytes were altered post-commit")
    func corruptPageRejectedByIntegrityChecksum() throws {
        try withTempDBPath { path in
            do {
                let db = try Database.open(at: path)
                defer { db.close() }
                try db.writeSync { (txn) throws(DBError) in
                    for i in 0 ..< 12 { try txn.put(key(String(format: "i%02d", i)), fatInlineValue(seed: UInt8(i))) }
                }
                // A clean database passes integrity end to end.
                #expect(try db.verifyIntegrity().kvCount == 12)
            }
            // Flip a single payload byte deep inside the first data page's cell area
            // (offset 200 is well past the 32-byte header, inside the value region). The
            // structural invariants may still hold, but the stamped XXH64 no longer
            // matches, so `verifyIntegrity` — which verifies checksums — must throw.
            let fh = try FileHandle(forUpdating: URL(fileURLWithPath: path))
            defer { try? fh.close() }
            let target = nodeFieldOffset(pageNo: Format.firstDataPage, fieldOffset: 200)
            try fh.seek(toOffset: target)
            let original = try fh.read(upToCount: 1) ?? Data([0])
            try fh.seek(toOffset: target)
            try fh.write(contentsOf: Data([original.first.map { $0 ^ 0xFF } ?? 0xFF]))
            try fh.close()

            let db = try Database.open(at: path)
            defer { db.close() }
            #expect(throws: DBError.self) {
                _ = try db.verifyIntegrity()
            }
        }
    }

    @Test("a truncated database file is rejected at open, not trapped")
    func truncatedFileRejectedAtOpen() throws {
        try withTempDBPath { path in
            do {
                let db = try Database.open(at: path)
                defer { db.close() }
                try db.writeSync { (txn) throws(DBError) in try txn.put(key("t"), key("v")) }
            }
            // Truncate the file to below even a single meta page: open must fail with a
            // clean error (bad magic / both metas invalid), never read out of bounds.
            let fh = try FileHandle(forUpdating: URL(fileURLWithPath: path))
            try fh.truncate(atOffset: 100)
            try fh.close()
            #expect(throws: DBError.self) {
                let db = try Database.open(at: path, options: DatabaseOptions(createIfMissing: false))
                db.close()
            }
        }
    }

    // MARK: - Local pure helpers

    /// Strict lexicographic (memcmp) "less than" over two byte buffers.
    private func lexicographicallyLess(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let n = min(a.count, b.count)
        for i in 0 ..< n where a[i] != b[i] {
            return a[i] < b[i]
        }
        return a.count < b.count
    }

    /// The value `KeyCodec` round-trips a given input back to: REAL normalizes
    /// -0.0 → +0.0 (mirrored on decode), everything else is identity for the
    /// non-NOCASE classes used here.
    private func normalizedForKey(_ v: Value) -> Value {
        if case .real(let d) = v, d == 0 { return .real(0.0) }
        return v
    }
}
