import ADSQLModel
import CSQLite
import Dispatch
import Synchronization
import Testing

@_spi(ADDBEngine) @testable import ADDBCore
@_spi(ADDBEngine) @testable import ADDBExec
@testable import ADDBTestSupport
@testable import ADSQL

// MARK: - Fixture

/// `docs(id INTEGER PRIMARY KEY, key TEXT, title TEXT COLLATE NOCASE, score
/// INTEGER, weight REAL, payload BLOB)` populated identically in both engines.
private enum DocsFixture {
    static let columns = ["id", "key", "title", "score", "weight", "payload"]

    static let definition = TableDefinition(
        "docs",
        columns: [
            ColumnDefinition("id", .integer, notNull: true),
            ColumnDefinition("key", .text, notNull: true),
            ColumnDefinition("title", .text, collation: .nocase),
            ColumnDefinition("score", .integer),
            ColumnDefinition("weight", .real),
            ColumnDefinition("payload", .blob)
        ],
        primaryKey: .rowidAlias(column: "id", autoincrement: true))

    static let sqliteDDL = """
        CREATE TABLE docs(
          id INTEGER PRIMARY KEY,
          key TEXT NOT NULL,
          title TEXT COLLATE NOCASE,
          score INTEGER,
          weight REAL,
          payload BLOB)
        """

    static func rows() -> [[Value]] {
        var rows: [[Value]] = []
        let titles = ["Alpha", "beta", "ALPHA", "Gamma", "delta", "Beta"]
        var rng = SplitMix64(seed: 0xD0C5_F1A7)
        for i in 1 ... 30 {
            let score: Value = (i % 7 == 0) ? .null : .integer(Int64(i % 11) - 3)
            let weight: Value = (i % 5 == 0) ? .null : .real(Double(Int64(rng.next() % 2000)) / 100.0 - 10)
            let title: Value = (i % 9 == 0) ? .null : .text(titles[i % titles.count])
            let payload: Value = (i % 4 == 0) ? .null : .blob([UInt8(i & 0xFF), UInt8((i * 3) & 0xFF)])
            rows.append([
                .integer(Int64(i)), .text("doc\(i)"), title, score, weight, payload
            ])
        }
        return rows
    }

    /// Opens a fresh ADSQL database alongside a SQLite mirror, both populated.
    static func make(_ dir: TempDir, _ name: String) throws -> (Database, SQLiteMirror) {
        let db = try Database.open(at: dir.file(name))
        try db.writeSync { (txn) throws(DBError) in try txn.createTable(definition) }
        let mirror = SQLiteMirror()
        try mirror.exec(sqliteDDL)
        for row in rows() {
            let dict = Dictionary(uniqueKeysWithValues: zip(columns, row))
            try db.writeSync { (txn) throws(DBError) in try txn.insert(into: "docs", dict) }
            try mirror.insertRow("docs", columns, row)
        }
        return (db, mirror)
    }
}

// MARK: - Differential SELECT

struct SQLSelectTests {
    static let queries: [String] = [
        "SELECT * FROM docs",
        "SELECT id, key FROM docs WHERE score > 2",
        "SELECT id FROM docs WHERE score IS NULL",
        "SELECT id, title FROM docs WHERE title = 'alpha'",
        "SELECT id FROM docs WHERE title LIKE 'b%'",
        "SELECT id, key FROM docs WHERE key LIKE 'doc1%'",
        "SELECT id, weight FROM docs WHERE weight IS NOT NULL ORDER BY weight",
        "SELECT id, score FROM docs ORDER BY score DESC, id ASC",
        "SELECT id FROM docs ORDER BY id LIMIT 5 OFFSET 3",
        "SELECT DISTINCT score FROM docs ORDER BY score",
        "SELECT DISTINCT title FROM docs",
        "SELECT DISTINCT title, score FROM docs",
        "SELECT DISTINCT weight FROM docs",
        "SELECT DISTINCT score FROM docs ORDER BY score DESC",
        "SELECT DISTINCT title FROM docs ORDER BY title LIMIT 2",
        "SELECT id, score * 2 AS doubled FROM docs WHERE score IS NOT NULL ORDER BY id",
        "SELECT id, key FROM docs WHERE id IN (2, 4, 6, 99) ORDER BY id",
        "SELECT id FROM docs WHERE score >= 0 AND weight < 0 ORDER BY id",
        "SELECT id, COALESCE(title, '<none>') AS t FROM docs ORDER BY id",
        "SELECT id FROM docs WHERE id = 7",
        "SELECT id, title FROM docs WHERE title COLLATE NOCASE = 'BETA' ORDER BY id",
        "SELECT id FROM docs WHERE LENGTH(key) > 4 ORDER BY id"
    ]

    @Test(arguments: queries)
    func matchesSQLite(_ sql: String) throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, mirror) = try DocsFixture.make(dir, "select.adsql")
        defer { db.close() }

        let ours = try db.prepare(sql).all().map(\.values)
        let theirs = try mirror.query(sql)
        let ordered = sql.lowercased().contains("order by")
        #expect(rowsMatch(ours, theirs, ordered: ordered), "\(sql): adsql \(ours) vs sqlite \(theirs)")
    }

    @Test func headerNamesAndAccessors() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, _) = try DocsFixture.make(dir, "header.adsql")
        defer { db.close() }

        let rows = try db.prepare("SELECT id, score * 2 AS doubled, key FROM docs WHERE id = 5").all()
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.columns == ["id", "doubled", "key"])
        #expect(row["id"] == .integer(5))
        #expect(row["key"] == .text("doc5"))
        #expect(row[0] == .integer(5))
        // Shared header: one allocation across the result set.
        let all = try db.prepare("SELECT id, key FROM docs").all()
        #expect(all.count == 30)
        #expect(all.dropFirst().allSatisfy { $0.header === all[0].header })
    }

    @Test func extremeLimitOffsetDoesNotTrap() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, _) = try DocsFixture.make(dir, "limit-overflow.adsql")
        defer { db.close() }
        // `offset + limit` would overflow-trap unsanitized; the bind-site clamp
        // keeps these safe. Offset past the end → no rows; huge limit → all rows.
        let maxInt = "9223372036854775807"
        #expect(try db.prepare("SELECT id FROM docs LIMIT \(maxInt) OFFSET \(maxInt)").all().isEmpty)
        #expect(try db.prepare("SELECT id FROM docs LIMIT \(maxInt)").all().count == 30)
    }

    @Test func parameterBinding() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, mirror) = try DocsFixture.make(dir, "params.adsql")
        defer { db.close() }

        let positional = try db.prepare("SELECT id FROM docs WHERE score > ? ORDER BY id").all(.integer(3))
        let positionalOracle = try mirror.query("SELECT id FROM docs WHERE score > ? ORDER BY id", [.integer(3)])
        #expect(rowsMatch(positional.map(\.values), positionalOracle, ordered: true))

        let named = try db.prepare("SELECT id FROM docs WHERE key = $k").all(["k": .text("doc12")])
        #expect(named.map(\.values) == [[.integer(12)]])
    }

    @Test func getReturnsFirstRow() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, _) = try DocsFixture.make(dir, "get.adsql")
        defer { db.close() }

        let row = try db.prepare("SELECT id FROM docs ORDER BY id DESC").get()
        #expect(row?[0] == .integer(30))
        let none = try db.prepare("SELECT id FROM docs WHERE id = 9999").get()
        #expect(none == nil)
    }
}

// MARK: - Bind-cache invalidation

struct SQLBindCacheTests {
    @Test func reboundAcrossCatalogVersions() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("rebind.adsql"))
        defer { db.close() }

        try db.writeSync { (txn) throws(DBError) in
            try txn.createTable(TableDefinition("t", columns: [ColumnDefinition("a", .integer)]))
            try txn.insert(into: "t", ["a": .integer(1)])
        }
        let statement = try db.prepare("SELECT * FROM t ORDER BY a")
        let before = try statement.all()
        #expect(before.first?.columns == ["a"])
        #expect(before.map(\.values) == [[.integer(1)]])

        // A DDL commit bumps the catalog version; the cached plan (header ["a"])
        // must be discarded and the same statement rebound to the new shape.
        try db.writeSync { (txn) throws(DBError) in
            try txn.dropTable("t")
            try txn.createTable(
                TableDefinition("t", columns: [ColumnDefinition("a", .integer), ColumnDefinition("b", .text)]))
            try txn.insert(into: "t", ["a": .integer(2), "b": .text("x")])
        }
        let after = try statement.all()
        #expect(after.first?.columns == ["a", "b"])
        #expect(after.map(\.values) == [[.integer(2), .text("x")]])
    }
}

// MARK: - Lazy vs full decode

struct LazyRowDecodeTests {
    private static let definition = TableDefinition(
        "r",
        columns: [
            ColumnDefinition("id", .integer, notNull: true),
            ColumnDefinition("a", .integer),
            ColumnDefinition("b", .text, collation: .nocase),
            ColumnDefinition("c", .real),
            ColumnDefinition("d", .blob),
            ColumnDefinition("e", .text, defaultValue: .value(.text("DEF")))
        ],
        primaryKey: .rowidAlias(column: "id", autoincrement: false))

    /// Independent oracle: the batch `RecordCodec.decode` path padded to the
    /// schema with the rowid filled in — distinct code from RowSlot's
    /// `cellOffsets`/`decodeCell` lazy path.
    private static func materialize(_ record: [UInt8], rowid: Int64, storedCount: Int) throws -> [Value] {
        var values = try record.withUnsafeBytes { try RecordCodec.decode($0) }
        let columns = definition.columns
        while values.count < columns.count {
            switch columns[values.count].defaultValue {
                case .value(let v): values.append(v)
                case .datetimeNow, nil: values.append(.null)
            }
        }
        values[definition.rowidAliasIndex!] = .integer(rowid)
        return values
    }

    @Test(arguments: [UInt64(1), 2, 3])
    func lazyEqualsFull(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        let slot = RowSlot(table: Self.definition)
        for _ in 0 ..< 300 {
            let rowid = Int64(rng.next() % 1_000_000)
            // Random full-width row (id placeholder overwritten by rowid).
            var stored: [Value] = [
                .integer(0),
                rng.next() % 4 == 0 ? .null : .integer(Int64(bitPattern: rng.next())),
                rng.next() % 4 == 0 ? .null : .text(randomText(&rng)),
                rng.next() % 4 == 0 ? .null : .real(Double(bitPattern: rng.next())),
                rng.next() % 4 == 0 ? .null : .blob(randomBytes(&rng)),
                rng.next() % 4 == 0 ? .null : .text(randomText(&rng))
            ]
            // Sometimes truncate trailing cells to exercise the default path.
            let storedCount = (rng.next() % 3 == 0) ? 4 : stored.count
            stored = Array(stored.prefix(storedCount))
            let record = RecordCodec.encode(stored)

            let full = try Self.materialize(record, rowid: rowid, storedCount: storedCount)
            var failure: DBError?
            record.withUnsafeBytes { raw in
                slot.load(rowid: rowid, span: raw)
                do throws(DBError) {
                    let lazy = try slot.materialize()
                    #expect(lazy.count == full.count)
                    for i in lazy.indices {
                        #expect(valueMatchesExact(lazy[i], full[i]), "column \(i): \(lazy[i]) vs \(full[i])")
                    }
                    // Re-read a couple of columns to exercise the decode cache.
                    #expect(valueMatchesExact(try slot.value(at: 0), .integer(rowid)))
                    #expect(valueMatchesExact(try slot.value(at: 2), full[2]))
                } catch {
                    failure = error
                }
            }
            if let failure { throw failure }
        }
    }

    private func randomText(_ rng: inout SplitMix64) -> String {
        let n = Int(rng.next() % 8)
        var s = ""
        for _ in 0 ..< n { s.unicodeScalars.append(Unicode.Scalar(UInt8(0x61 + rng.next() % 26))) }
        return s
    }
    private func randomBytes(_ rng: inout SplitMix64) -> [UInt8] {
        let n = Int(rng.next() % 6)
        return (0 ..< n).map { _ in UInt8(rng.next() & 0xFF) }
    }
}

private func valueMatchesExact(_ a: Value, _ b: Value) -> Bool {
    if case .real(let x) = a, case .real(let y) = b {
        return x.bitPattern == y.bitPattern || x == y
    }
    return a == b
}

// MARK: - Concurrency (TSan lane)

struct SQLStatementConcurrencyTests {
    @Test func oneStatementManyTasks() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let (db, _) = try DocsFixture.make(dir, "concurrent.adsql")
        defer { db.close() }

        let statement = try db.prepare("SELECT id, score FROM docs WHERE score IS NOT NULL ORDER BY id")
        let expected = try statement.all().map(\.values)
        #expect(!expected.isEmpty)

        let mismatch = Mutex<Bool>(false)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0 ..< 60 {
                guard let rows = try? statement.all().map(\.values) else {
                    mismatch.withLock { $0 = true }
                    return
                }
                if rows != expected { mismatch.withLock { $0 = true } }
            }
        }
        #expect(mismatch.withLock { $0 } == false)
    }
}
