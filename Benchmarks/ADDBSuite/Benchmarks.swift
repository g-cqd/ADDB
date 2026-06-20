@_spi(ADDBEngine) import ADDBCore
// `MemberImportVisibility` (a `strictSettings` upcoming feature) requires importing the module that
// DECLARES the relational model types directly, not relying on ADDBCore's `public import` re-export —
// `TableDefinition` / `ColumnDefinition` / `IndexDefinition` / `DBError` / `Value` live in ADSQLModel.
// Mirrors the sibling `ADDBCoreTests` files (which import ADSQLModel alongside the @_spi ADDBCore).
import ADSQLModel
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

    let keys: [[UInt8]] = (0 ..< 2000).map { Array("key/\($0)".utf8) }
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

    // Relational full-table scan: the path that materializes each row into a `Row`
    // (RowCursor.next → materializeRow). It is sensitive to the per-row column-name
    // array (hoisted to cursor creation) and per-value inline copies. A table of
    // INTEGER + TEXT + INTEGER rows so materialization decodes a real mix.
    let rowCount = 5000
    let scanDB = try! Database.open(at: tempDBPath())
    try! scanDB.writeSync { (txn) throws(DBError) in
        try txn.createTable(
            TableDefinition(
                "scan",
                columns: [
                    ColumnDefinition("id", .integer),
                    ColumnDefinition("name", .text),
                    ColumnDefinition("n", .integer)
                ],
                primaryKey: .rowidAlias(column: "id", autoincrement: false)))
        for i in 0 ..< rowCount {
            try txn.insert(
                into: "scan",
                ["id": .integer(Int64(i)), "name": .text("row-\(i)-payload"), "n": .integer(Int64(i * 7))])
        }
    }
    Benchmark("relation/scan 5000", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations {
            try? scanDB.read { (txn) throws(DBError) in
                try txn.withRowCursor(table: "scan") { (cursor) throws(DBError) in
                    while let row = try cursor.next() { blackHole(row) }
                }
            }
        }
    }

    // createIndex backfill: scans every table row and writes an index entry per row
    // (Relation.backfillIndex). Re-created each iteration on a fresh handle so the
    // backfill scan (the zero-copy `withValueBytes` site) is what is measured.
    let backfillDB = try! Database.open(at: tempDBPath())
    try! backfillDB.writeSync { (txn) throws(DBError) in
        try txn.createTable(
            TableDefinition(
                "bf",
                columns: [
                    ColumnDefinition("id", .integer),
                    ColumnDefinition("name", .text),
                    ColumnDefinition("n", .integer)
                ],
                primaryKey: .rowidAlias(column: "id", autoincrement: false)))
        for i in 0 ..< rowCount {
            try txn.insert(
                into: "bf",
                ["id": .integer(Int64(i)), "name": .text("row-\(i)-payload"), "n": .integer(Int64(i * 7))])
        }
    }
    var backfillSeq = 0
    Benchmark("relation/createIndex backfill 5000", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations {
            backfillSeq += 1
            let indexName = "bf_n_\(backfillSeq)"
            try? backfillDB.writeSync { (txn) throws(DBError) in
                try txn.createIndex(IndexDefinition(indexName, on: "bf", columns: ["n"]))
            }
        }
    }
}
