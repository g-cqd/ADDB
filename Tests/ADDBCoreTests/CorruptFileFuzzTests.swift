import ADTestKit
import Foundation
import Testing

// White-box access to the engine, identical to `EngineCharacterizationTests`:
// `@testable` reaches `internal` symbols and `@_spi(ADDBEngine)` reaches the broad
// engine surface (cursors). This suite hardens the corrupt-file contract: opening
// and reading a byte-mutated database file may only throw a `DBError` or return
// well-formed results — it must NEVER trap, hang, OOM, or read out of bounds. A
// `precondition`/`fatalError`/OOB on any mutation aborts the test process, which is
// exactly the loud signal of a remaining unhardened trap vector.
@_spi(ADDBEngine) @testable import ADDBCore

@Suite("ADDB corrupt-file fuzz")
struct ADDBCorruptFileFuzzTests {
    // The deterministic generator and the scratch-path helper are now the shared
    // `ADTestKit.SeededRNG` (its `next` / `next(upTo:)` stream is byte-for-byte the old
    // local `SplitMix64`, so this seed reproduces the identical corpus) and
    // `ADTestKit.withTempPath` (same `-wal`/`-shm`/`-lock` sibling cleanup).

    private func key(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// A pristine valid database plus the metadata the fuzz loop needs.
    private struct Corpus {
        var bytes: [UInt8]
        var inlineKeys: [[UInt8]]
        var overflowKeys: [[UInt8]]
    }

    /// Builds a non-trivial valid database and returns its pristine bytes. The shape
    /// is chosen to exercise every protected trap vector:
    /// - several dozen near-page-sized inline values fill 16 KiB leaves (~4 cells
    ///   each) and grow the main B+tree to depth >= 2, so corruption can land on a
    ///   branch page, its separators, a slot array, or a leaf cell (the structural-
    ///   validate / slot-OOB / multi-level walk / depth-cap vectors);
    /// - interleaved overflow values (each past `Format.maxInlineCellSize` = 4064)
    ///   create multi-page overflow chains (the reserve-cap / cyclic-chain vectors).
    /// The file stays a few hundred KiB and the live entry count stays small, so each
    /// iteration's full rewrite + open + scan + deep verify is cheap.
    private func buildCorpus(at path: String) throws -> Corpus {
        var inlineKeys: [[UInt8]] = []
        var overflowKeys: [[UInt8]] = []
        do {
            let db = try Database.open(at: path)
            defer { db.close() }
            try db.writeSync { (txn) throws(DBError) in
                // Each inline value is sized just under `maxInlineCellSize` (4064), so a
                // 16 KiB leaf holds only ~4 cells: a few dozen such keys fill several
                // leaves and grow the main B+tree to depth >= 2 with a *small entry
                // count*. That matters because every fuzz iteration does a full tree
                // scan + deep verify, so keeping the live entry count low (rather than
                // thousands of tiny cells) is what makes thousands of iterations fast,
                // while the depth-2 shape still exposes branch pages, separators, slot
                // arrays, and the multi-level walk to corruption.
                let inlineValueSize = Format.maxInlineCellSize - 64
                for i in 0 ..< 60 {
                    let k = key(String(format: "key-%04d", i))
                    if i % 12 == 0 {
                        // Overflow value: just past maxInlineCellSize, so it spills to a
                        // (short) overflow chain — the reserve-cap / cyclic-chain vector.
                        let size = Format.maxInlineCellSize + 1024 + (i * 7)
                        try txn.put(k, [UInt8](repeating: UInt8(i & 0xFF), count: size))
                        overflowKeys.append(k)
                    } else {
                        try txn.put(k, [UInt8](repeating: UInt8(i & 0xFF), count: inlineValueSize))
                        inlineKeys.append(k)
                    }
                }
            }
        }
        let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        // Sanity: the build must have grown well past the two meta pages and must
        // hold overflow chains, or the fuzz would only ever touch a trivial file.
        #expect(bytes.count > 8 * Format.pageSize)
        #expect(!overflowKeys.isEmpty)
        return Corpus(bytes: bytes, inlineKeys: inlineKeys, overflowKeys: overflowKeys)
    }

    /// Applies the seeded mutations to a fresh copy of `pristine` and writes it to
    /// `url`, returning the mutation list (offset, byte) so a trap can be reported as
    /// a precise repro.
    private func mutate(
        _ pristine: [UInt8], metaEnd: Int, count: Int, rng: inout SeededRNG, to url: URL
    ) throws -> [(offset: Int, value: UInt8)] {
        let nodeRegionWidth = pristine.count - metaEnd
        var mutated = pristine
        var applied: [(offset: Int, value: UInt8)] = []
        for _ in 0 ..< count {
            let offset = metaEnd + rng.next(upTo: nodeRegionWidth)
            let value = UInt8(rng.next(upTo: 256))
            mutated[offset] = value
            applied.append((offset, value))
        }
        try Data(mutated).write(to: url)
        // Drop the engine's siblings so each open sees only the freshly mutated file.
        for suffix in ["-wal", "-shm", "-lock"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        return applied
    }

    /// Drives the read-side surface the hardening protects, swallowing any thrown
    /// `DBError` (expected-and-fine). The PASS condition is solely that the process
    /// survives — a trap inside any of these aborts it. `materializeValues` gates the
    /// value-reassembly paths (`get`/`forEach` concatenate overflow chains, which
    /// triggers the `Overflow.read` reserve cap): kept off in the wide structural
    /// sweep and on in the smaller reassembly sweep, so the wide sweep stays fast.
    private func exerciseReads(
        at path: String, pointKeys: [[UInt8]], materializeValues: Bool
    ) {
        // open itself may reject the file (e.g. a structurally bad live root).
        guard let db = try? Database.open(at: path) else { return }
        defer { db.close() }

        // Point lookups for known keys: walk to the leaf and decode the cell. Each
        // may throw `corruptPage`/`integrityFailure` or return a well-formed (and
        // possibly different) value/nil. When `pointKeys` includes overflow-backed
        // keys, this materializes their chains (reserve-cap / cyclic-chain guards).
        for k in pointKeys {
            _ = try? db.read { (txn) throws(DBError) in try txn.get(k) }
        }

        // Full ordered cursor scan over the whole tree, reading each entry's key and
        // value *reference* (no overflow concatenation). Exercises the branch/leaf
        // walk, separator descent, slot-offset bounds, and leaf-cell decode on every
        // page — the structural trap vectors — cheaply, on every iteration.
        _ = try? db.read { (txn) throws(DBError) in
            try txn.withCursor { (cursor) throws(DBError) in
                guard try cursor.move(to: .first) else { return }
                repeat {
                    _ = try cursor.withCurrent { (rawKey, _) in rawKey.count }
                } while try cursor.next()
            }
        }

        // The full-scan entry point that *materializes* every value (concatenating
        // overflow chains): the other reassembly path besides `get`. Gated, since it
        // is the one that pays the `Overflow.read` reserve cap under a corrupt length.
        if materializeValues {
            _ = try? db.read { (txn) throws(DBError) in
                try txn.forEach { (_, _) throws(DBError) in }
            }
        }

        // Deep integrity check: full structural validation (page types, in-node key
        // order, separator bounds, uniform leaf depth, the B+tree depth cap, and the
        // overflow-chain `dataLen`/length bounds) with checksums, plus the index/row
        // bijection. Any corruption it detects surfaces as a thrown `DBError`. It
        // walks overflow chains for length accounting without the eager reserve, so
        // it stays cheap even when a length field is corrupt — hence on every pass.
        _ = try? db.verifyIntegrity(deep: true)
    }

    @Test("byte-mutated node region never traps, only throws DBError or returns")
    func mutatedNodeRegionNeverTraps() throws {
        // Fixed seed → fully deterministic, reproducible run.
        let seed: UInt64 = 0xADDB_F0E5_1234_5678
        let maxMutationsPerIteration = 8
        // Two seeded sweeps, both fast (<~10s total):
        //  - structuralIterations: the wide sweep over the structural trap vectors
        //    (open / scan / point-gets on inline keys / deep verify), value
        //    materialization off so each iteration is cheap;
        //  - reassemblyIterations: a smaller sweep with materialization on (point
        //    gets on the overflow keys + full `forEach`), locking the overflow
        //    reserve-cap / cyclic-chain path, whose corrupt-length case legitimately
        //    does bounded (capped) work and so must not run thousands of times.
        let structuralIterations = 4000
        let reassemblyIterations = 1000

        try withTempPath(prefix: "addb-fuzz") { buildPath in
            let corpus = try buildCorpus(at: buildPath)
            let pristine = corpus.bytes

            // Mutate only the NODE region — byte offsets past the two checksummed
            // meta pages — so the database still opens (a torn meta would be rejected
            // up front and exercise nothing).
            let metaEnd = Int(Format.metaPageCount) * Format.pageSize
            #expect(pristine.count - metaEnd > 0)

            // Sample keys spanning the range for the wide structural sweep (inline
            // only, so it never pays the reserve cap), plus the overflow keys for the
            // reassembly sweep.
            let stride = max(1, corpus.inlineKeys.count / 16)
            let inlineSample = Swift.stride(from: 0, to: corpus.inlineKeys.count, by: stride)
                .map { corpus.inlineKeys[$0] }

            var rng = SeededRNG(seed: seed)
            // A trap aborts the process, so the surviving signal is the (seed,
            // iteration) pair plus the exact mutation list. Setting `ADDB_FUZZ_TRACE`
            // prints each iteration's mutations *before* it is exercised, so a crash
            // run's final printed line is the precise repro (offset + byte) to shrink.
            let trace = ProcessInfo.processInfo.environment["ADDB_FUZZ_TRACE"] != nil
            func report(_ phase: String, _ iteration: Int, _ muts: [(offset: Int, value: UInt8)]) {
                guard trace else { return }
                let list = muts.map { "\($0.offset):0x\(String($0.value, radix: 16))" }
                    .joined(separator: ",")
                print("FUZZ \(phase) i=\(iteration) seed=0x\(String(seed, radix: 16)) muts=[\(list)]")
            }

            try withTempPath(prefix: "addb-fuzz") { scratchPath in
                let scratchURL = URL(fileURLWithPath: scratchPath)

                for iteration in 0 ..< structuralIterations {
                    let muts = 1 + rng.next(upTo: maxMutationsPerIteration)
                    let applied = try mutate(
                        pristine, metaEnd: metaEnd, count: muts, rng: &rng, to: scratchURL)
                    report("structural", iteration, applied)
                    exerciseReads(
                        at: scratchPath, pointKeys: inlineSample, materializeValues: false)
                }

                for iteration in 0 ..< reassemblyIterations {
                    let muts = 1 + rng.next(upTo: maxMutationsPerIteration)
                    let applied = try mutate(
                        pristine, metaEnd: metaEnd, count: muts, rng: &rng, to: scratchURL)
                    report("reassembly", iteration, applied)
                    exerciseReads(
                        at: scratchPath, pointKeys: corpus.overflowKeys, materializeValues: true)
                }
            }

            // Reaching here means no mutation trapped/crashed/hung across either
            // sweep: the invariant "throws DBError OR succeeds, never traps" held for
            // the whole seeded corpus.
            #expect(Bool(true))
        }
    }
}
