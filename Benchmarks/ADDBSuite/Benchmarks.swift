@_spi(ADDBEngine) import ADDBCore
// ADDBExec: the SQL executor surface (`prepare`/`Statement`/`all`/`run`) for the SELECT benchmarks.
// ADDBFTS: `Database.openFTS` + the MATCH/bm25 evaluator for the full-text benchmarks.
import ADDBExec
import ADDBFTS
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

    // MARK: SQL execution — the prepared-statement READ path (parse-once, execute-many) the in-process
    // server uses (and the path the G3 read-swap would serve from). A point lookup by rowid, a filtered
    // range scan with ORDER BY + LIMIT, and a COUNT aggregate over an INTEGER/TEXT/INTEGER table, so the
    // executor's plan + row materialization are timed end to end — coverage the KV/relational primitives
    // above don't reach.
    let sqlDB = try! Database.open(at: tempDBPath())
    try! sqlDB.writeSync { (txn) throws(DBError) in
        try txn.createTable(
            TableDefinition(
                "rel",
                columns: [
                    ColumnDefinition("id", .integer),
                    ColumnDefinition("name", .text),
                    ColumnDefinition("n", .integer)
                ],
                primaryKey: .rowidAlias(column: "id", autoincrement: false)))
        for i in 0 ..< rowCount {
            try txn.insert(
                into: "rel",
                ["id": .integer(Int64(i)), "name": .text("row-\(i)-payload"), "n": .integer(Int64(i * 7))])
        }
    }
    // A prepared `Statement` holds its `Database` `unowned`, so each closure must keep the db alive
    // (`withExtendedLifetime`) — the suite's other benchmarks get this for free by calling methods
    // directly on the captured db handle.
    let pointStmt = try! sqlDB.prepare("SELECT id, name, n FROM rel WHERE id = ?")
    Benchmark("sql/point-lookup by rowid", configuration: cowMetrics) { bm in
        withExtendedLifetime(sqlDB) {
            for _ in bm.scaledIterations { blackHole(try! pointStmt.all(.integer(Int64(rowCount / 2)))) }
        }
    }
    let rangeStmt = try! sqlDB.prepare("SELECT id, name FROM rel WHERE n > ? ORDER BY n ASC LIMIT 50")
    Benchmark("sql/range-scan WHERE+ORDER+LIMIT 50", configuration: cowMetrics) { bm in
        withExtendedLifetime(sqlDB) {
            for _ in bm.scaledIterations { blackHole(try! rangeStmt.all(.integer(Int64(rowCount * 3)))) }
        }
    }
    let countStmt = try! sqlDB.prepare("SELECT COUNT(*) FROM rel WHERE n > ?")
    Benchmark("sql/count aggregate", configuration: cowMetrics) { bm in
        withExtendedLifetime(sqlDB) {
            for _ in bm.scaledIterations { blackHole(try! countStmt.all(.integer(Int64(rowCount * 2)))) }
        }
    }

    // MARK: full-text search — the bm25-ranked MATCH path that backs the search cascade (the most
    // important previously-uncovered ADDB hot path). An FTS5 table of short documents is built once;
    // the benchmark times `… WHERE f MATCH ? ORDER BY rank LIMIT 20` (FTS evaluator → bm25 scorer →
    // top-k sort) for an OR-ish two-term query and an explicit AND query.
    let ftsDocs = 400
    let ftsTerms = ["swift", "view", "data", "async", "actor", "layout", "render", "query", "index", "cache"]
    let ftsDB = try! Database.open(at: tempDBPath())
    ftsDB.enableFullTextSearch()  // installs the MATCH/rank/bm25 evaluator (idempotent)
    try! ftsDB.prepare("CREATE VIRTUAL TABLE f USING fts5(title, body, tokenize='porter unicode61')").run()
    let ftsInsert = try! ftsDB.prepare("INSERT INTO f(rowid, title, body) VALUES(?, ?, ?)")
    for i in 0 ..< ftsDocs {
        let termA = ftsTerms[i % ftsTerms.count]
        let termB = ftsTerms[(i / ftsTerms.count) % ftsTerms.count]
        let termC = ftsTerms[(i * 3) % ftsTerms.count]
        try! ftsInsert.run(
            .integer(Int64(i + 1)),
            .text("\(termA) \(termB) document \(i)"),
            .text("a short note about \(termA) and \(termB) in the \(termC) subsystem"))
    }
    let matchStmt = try! ftsDB.prepare("SELECT rowid, rank FROM f WHERE f MATCH ? ORDER BY rank LIMIT 20")
    Benchmark("fts/match two-term bm25 top-20") { bm in
        withExtendedLifetime(ftsDB) {
            for _ in bm.scaledIterations { blackHole(try! matchStmt.all(.text("swift view"))) }
        }
    }
    let matchAndStmt = try! ftsDB.prepare("SELECT rowid, rank FROM f WHERE f MATCH ? ORDER BY rank LIMIT 20")
    Benchmark("fts/match AND bm25 top-20") { bm in
        withExtendedLifetime(ftsDB) {
            for _ in bm.scaledIterations { blackHole(try! matchAndStmt.all(.text("swift AND layout"))) }
        }
    }
}
