@_spi(ADDBEngine) import ADDBCore
import Benchmark
import Foundation

// ADDB's benchmark suite on ordo-one's framework, matching the sibling ADFoundation / ADJSON suites.
// Run with `ADDB_DEV=1 swift package benchmark`. The guards track `.mallocCountTotal` (CI installs
// jemalloc) so a reintroduced copy-on-write copy or per-append reallocation in the storage codec path
// (RecordCodec / KeyCodec, exercised through put/get) trips the threshold instead of rotting silently.

private func tempDBPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("addb-bench-\(UInt64.random(in: 0..<UInt64.max)).adsql").path
}

nonisolated(unsafe) let benchmarks = {
    let cowMetrics = Benchmark.Configuration(metrics: [.wallClock, .throughput, .mallocCountTotal])

    let keys: [[UInt8]] = (0..<2000).map { Array("key/\($0)".utf8) }
    let value = [UInt8](repeating: 0xAB, count: 64)

    // Setup (open + populate) happens here, outside the measured closures, so only the codec/B+tree
    // work is timed. The handles intentionally outlive the run (benchmark process); the temp files are
    // small and live under the OS temp dir.
    let putDB = try! Database.open(at: tempDBPath())
    Benchmark("storage/put 2000", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations {
            try? putDB.writeSync { (txn) throws(DBError) in
                for k in keys { try txn.put(k, value) }  // re-put overwrites: still encodes each record
            }
        }
    }

    let getDB = try! Database.open(at: tempDBPath())
    try! getDB.writeSync { (txn) throws(DBError) in for k in keys { try txn.put(k, value) } }
    Benchmark("storage/get 2000", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations {
            try? getDB.read { (txn) throws(DBError) in
                for k in keys { blackHole(try txn.get(k)) }
            }
        }
    }
}
