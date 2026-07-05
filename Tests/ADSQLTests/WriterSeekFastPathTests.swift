import ADSQLModel
import Testing

@_spi(ADDBEngine) @testable import ADDBCore
@_spi(ADDBEngine) @testable import ADDBExec
@testable import ADDBTestSupport
@testable import ADSQL

/// Regression tests for the `collectMatches` unique-index seek fast path (Writer+FTS.swift). An
/// UPDATE/DELETE keyed on a single-column UNIQUE index — a TEXT `PRIMARY KEY`'s implied autoindex, or a
/// `UNIQUE` column — must produce results byte-identical to the former full-table scan. That equivalence
/// is what lets the crawl's per-batch `markCrawlProcessed` (`UPDATE crawl_state … WHERE path IN (…)`) run
/// in O(k·log N) index seeks instead of O(N·k) (a whole-table scan that re-scans the k-element IN list
/// per row). Every case is diffed against real SQLite via `SQLiteMirror`.
@Suite("Writer unique-key seek fast path == full scan")
struct WriterSeekFastPathTests {
    // `path TEXT PRIMARY KEY` is exactly the crawl_state shape: a non-integer PK, which the DDL binder
    // desugars into the implied unique index `sqlite_autoindex_crawl_state_1` on (path).
    private static let ddl =
        "CREATE TABLE crawl_state (path TEXT PRIMARY KEY, status TEXT NOT NULL DEFAULT 'pending', "
        + "depth INTEGER NOT NULL DEFAULT 0)"
    private static let seed = [
        "INSERT INTO crawl_state (path, depth) VALUES ('swiftui', 0)",
        "INSERT INTO crawl_state (path, depth) VALUES ('swiftui/view', 1)",
        "INSERT INTO crawl_state (path, depth) VALUES ('uikit', 0)",
        "INSERT INTO crawl_state (path, depth) VALUES ('uikit/uiview', 1)",
        "INSERT INTO crawl_state (path, depth) VALUES ('foundation', 0)"
    ]

    /// A fresh JSON-backed engine + a parallel SQLite mirror, both seeded with the same crawl_state rows.
    private func openSeeded() throws -> (Database, SQLiteMirror, TempDir) {
        let dir = TempDir()
        let db = try Database.openJSON(at: dir.file("seek.adsql"))
        let mirror = SQLiteMirror()
        for sql in [Self.ddl] + Self.seed {
            try db.prepare(sql).run()
            try mirror.exec(sql)
        }
        return (db, mirror, dir)
    }

    private func table(_ db: Database) throws -> [[Value]] {
        try db.prepare("SELECT path, status, depth FROM crawl_state ORDER BY path").all().map(\.values)
    }

    private func mirrorTable(_ mirror: SQLiteMirror) throws -> [[Value]] {
        try mirror.query("SELECT path, status, depth FROM crawl_state ORDER BY path")
    }

    @Test("UPDATE … WHERE path IN (params) marks exactly the listed rows — the markCrawlProcessed shape")
    func inListParamUpdateMatchesSQLite() throws {
        let (db, mirror, dir) = try openSeeded()
        _ = dir  // hold the temp dir for the test's lifetime
        // The literal statement CrawlPersist.markCrawlProcessed issues, with a path that does NOT exist
        // ('missing') to prove an absent key is a silent no-op rather than an error.
        try db.prepare("UPDATE crawl_state SET status = 'processed' WHERE path IN ($p0, $p1, $p2)")
            .run(["p0": .text("swiftui"), "p1": .text("uikit"), "p2": .text("missing")])
        try mirror.exec(
            "UPDATE crawl_state SET status = 'processed' WHERE path IN ('swiftui', 'uikit', 'missing')")

        let ours = try table(db)
        #expect(rowsMatch(ours, try mirrorTable(mirror), ordered: true), "\(ours)")
        #expect(ours.contains([.text("swiftui"), .text("processed"), .integer(0)]))
        #expect(ours.contains([.text("uikit"), .text("processed"), .integer(0)]))
        #expect(ours.contains([.text("foundation"), .text("pending"), .integer(0)]))
    }

    @Test("UPDATE/DELETE … WHERE path = param touch exactly the one keyed row")
    func pointUpdateAndDeleteMatchSQLite() throws {
        let (db, mirror, dir) = try openSeeded()
        _ = dir
        try db.prepare("UPDATE crawl_state SET depth = 9 WHERE path = $p").run(["p": .text("swiftui/view")])
        try mirror.exec("UPDATE crawl_state SET depth = 9 WHERE path = 'swiftui/view'")
        try db.prepare("DELETE FROM crawl_state WHERE path = $p").run(["p": .text("uikit")])
        try mirror.exec("DELETE FROM crawl_state WHERE path = 'uikit'")

        let ours = try table(db)
        #expect(rowsMatch(ours, try mirrorTable(mirror), ordered: true), "\(ours)")
        #expect(ours.count == 4)  // one deleted
        #expect(ours.contains([.text("swiftui/view"), .text("pending"), .integer(9)]))
    }

    @Test("a compound predicate on the key still matches the scan (seek narrows, predicate decides)")
    func compoundPredicateMatchesSQLite() throws {
        let (db, mirror, dir) = try openSeeded()
        _ = dir
        // `path = 'swiftui'` seeks the row, but the extra `depth = 5` condition must exclude it (depth 0);
        // the re-evaluation of the FULL predicate on the seeked row keeps this identical to the scan.
        try db.prepare("UPDATE crawl_state SET status = 'x' WHERE path = $p AND depth = $d")
            .run(["p": .text("swiftui"), "d": .integer(5)])
        try mirror.exec("UPDATE crawl_state SET status = 'x' WHERE path = 'swiftui' AND depth = 5")

        let ours = try table(db)
        #expect(rowsMatch(ours, try mirrorTable(mirror), ordered: true), "\(ours)")
        #expect(ours.contains([.text("swiftui"), .text("pending"), .integer(0)]))  // untouched
    }

    @Test("UPDATE … WHERE <non-unique indexed col> = param updates EVERY matching row (per-key denorm)")
    func nonUniqueKeyUpdateMatchesSQLite() throws {
        let dir = TempDir()
        _ = dir
        let db = try Database.openJSON(at: dir.file("nonuniq.adsql"))
        let mirror = SQLiteMirror()
        // A non-unique index on `framework` — the shape the import's per-root denorm UPDATEs hit.
        let statements = [
            "CREATE TABLE docs (id INTEGER PRIMARY KEY, framework TEXT NOT NULL, root_display TEXT)",
            "CREATE INDEX idx_docs_framework ON docs(framework)",
            "INSERT INTO docs (id, framework) VALUES (1, 'swiftui')",
            "INSERT INTO docs (id, framework) VALUES (2, 'swiftui')",
            "INSERT INTO docs (id, framework) VALUES (3, 'uikit')",
            "INSERT INTO docs (id, framework) VALUES (4, 'swiftui')",
            "INSERT INTO docs (id, framework) VALUES (5, 'foundation')"
        ]
        for sql in statements {
            try db.prepare(sql).run()
            try mirror.exec(sql)
        }
        // One UPDATE keyed on the non-unique `framework` must touch ALL three swiftui rows (not just the
        // first) — the range walk, not a single firstRowid seek — and leave uikit/foundation alone.
        try db.prepare("UPDATE docs SET root_display = $d WHERE framework = $f")
            .run(["d": .text("SwiftUI"), "f": .text("swiftui")])
        try mirror.exec("UPDATE docs SET root_display = 'SwiftUI' WHERE framework = 'swiftui'")

        let ours = try db.prepare("SELECT id, framework, root_display FROM docs ORDER BY id").all()
            .map(\.values)
        let theirs = try mirror.query("SELECT id, framework, root_display FROM docs ORDER BY id")
        #expect(rowsMatch(ours, theirs, ordered: true), "\(ours)")
        #expect(ours.filter { $0[2] == .text("SwiftUI") }.count == 3)
    }

    @Test("DELETE … WHERE the LEADING column of a COMPOSITE index = param seeks the prefix, not a scan")
    func compositeLeadingColumnDeleteMatchesSQLite() throws {
        let dir = TempDir()
        _ = dir
        let db = try Database.openJSON(at: dir.file("composite.adsql"))
        let mirror = SQLiteMirror()
        // The document_relationships shape: a COMPOSITE UNIQUE(from_key, to_key, relation_type) with NO
        // single-column from_key index. The crawl's replace path issues `DELETE … WHERE from_key = ?`; the
        // seek fast path must use the composite index's LEADING column (from_key) rather than a full scan —
        // the O(N²) that otherwise collapses a re-crawl of a large corpus. Diffed against SQLite, which
        // likewise seeks the leading column of its composite index.
        let statements = [
            "CREATE TABLE document_relationships (id INTEGER PRIMARY KEY, from_key TEXT NOT NULL, "
                + "to_key TEXT NOT NULL, relation_type TEXT NOT NULL, "
                + "UNIQUE(from_key, to_key, relation_type))",
            "INSERT INTO document_relationships (from_key, to_key, relation_type) "
                + "VALUES ('swiftui/view', 'swiftui/text', 'child')",
            "INSERT INTO document_relationships (from_key, to_key, relation_type) "
                + "VALUES ('swiftui/view', 'swiftui/image', 'child')",
            "INSERT INTO document_relationships (from_key, to_key, relation_type) "
                + "VALUES ('swiftui/view', 'swiftui/view', 'conformsTo')",
            "INSERT INTO document_relationships (from_key, to_key, relation_type) "
                + "VALUES ('uikit/uiview', 'uikit/uilabel', 'child')",
            "INSERT INTO document_relationships (from_key, to_key, relation_type) "
                + "VALUES ('foundation/url', 'foundation/data', 'related')"
        ]
        for sql in statements {
            try db.prepare(sql).run()
            try mirror.exec(sql)
        }
        // The replace-path DELETE: drop every relationship of the re-crawled page (the three 'swiftui/view'
        // rows), leaving the other pages' rows untouched.
        try db.prepare("DELETE FROM document_relationships WHERE from_key = $k")
            .run(["k": .text("swiftui/view")])
        try mirror.exec("DELETE FROM document_relationships WHERE from_key = 'swiftui/view'")

        let ours =
            try db.prepare(
                "SELECT from_key, to_key, relation_type FROM document_relationships "
                    + "ORDER BY from_key, to_key, relation_type"
            )
            .all().map(\.values)
        let theirs = try mirror.query(
            "SELECT from_key, to_key, relation_type FROM document_relationships "
                + "ORDER BY from_key, to_key, relation_type")
        #expect(rowsMatch(ours, theirs, ordered: true), "\(ours)")
        #expect(ours.count == 2)  // the three swiftui/view rows gone; uikit + foundation remain
        #expect(!ours.contains { $0[0] == .text("swiftui/view") })
    }
}
