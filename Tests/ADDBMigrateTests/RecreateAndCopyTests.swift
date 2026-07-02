@_spi(ADDBEngine) import ADDBCore
import ADDBMigrate
import ADSQL
import ADSQLModel
import Testing

@_spi(ADDBEngine) @testable import ADDBExec

/// The recreate-and-copy column-shape change, exercised end to end through one
/// migration transaction. ADDB has no `ALTER TABLE`, so a column change stages the
/// reshaped rows, drops the old table, recreates it under its final name, copies
/// the staged rows back (preserving rowids), recreates dependent indexes, rebuilds
/// the FTS mirror once, and recreates the FTS-sync triggers — all atomically.
///
/// Engine constraint exercised here: the FK-OWNING side is reshaped. ADDB blocks
/// `DROP TABLE` on a parent that still has inbound-FK children, and its
/// `PRAGMA foreign_keys` is a no-op (FKs are always enforced), so the SQLite
/// "disable FKs, rebuild parent, re-enable" recipe is unavailable — reshaping a
/// parent additionally requires rebuilding its children. See
/// ``RecreateAndCopy`` for that documented limitation.
struct RecreateAndCopyTests {
    /// Builds a v1 schema: a `doc` parent (rowid alias `id`) and a `note` child
    /// that OWNS the FK (`note.doc_id REFERENCES doc`). The recreate-and-copy
    /// reshapes the FK-owning child — the achievable single-table case on this
    /// engine (a parent with inbound children cannot be dropped; see the suite's
    /// note). A plain-table stand-in `note_fts` mirrors `note` via AFTER triggers,
    /// and a `fts_rebuilds` counter lets a test assert the bulk rebuild fires once.
    /// Returns at cursor version 1.
    private func seededDatabase() throws -> TempDatabase {
        let temp = try TempDatabase()
        let setup = Migration(version: 1, name: "initial schema") { ctx throws(DBError) in
            try ctx.run("CREATE TABLE doc(id INTEGER PRIMARY KEY, title TEXT NOT NULL)")
            try ctx.run(
                """
                CREATE TABLE note(
                  id INTEGER PRIMARY KEY,
                  doc_id INTEGER REFERENCES doc ON DELETE RESTRICT,
                  body TEXT NOT NULL)
                """)
            // A plain-table stand-in for an FTS index over `note`, plus the
            // AFTER-INSERT trigger that mirrors each note row into it (the per-row
            // sync the bulk copy must suspend). The counter proves the bulk rebuild
            // fires exactly once.
            try ctx.run("CREATE TABLE note_fts(rowid INTEGER PRIMARY KEY, body TEXT)")
            try ctx.run("CREATE TABLE fts_rebuilds(n INTEGER NOT NULL)")
            try ctx.run("INSERT INTO fts_rebuilds(n) VALUES(0)")
            try ctx.run(
                """
                CREATE TRIGGER note_fts_ai AFTER INSERT ON note BEGIN
                  INSERT INTO note_fts(rowid, body) VALUES(NEW.id, NEW.body);
                END
                """)
            // Parent rows (untouched by the reshape).
            try ctx.run("INSERT INTO doc(id, title) VALUES(10, 'alpha')")
            try ctx.run("INSERT INTO doc(id, title) VALUES(25, 'bravo')")
            try ctx.run("INSERT INTO doc(id, title) VALUES(99, 'charlie')")
            // Child rows with NON-CONTIGUOUS rowids (so rowid preservation is a real
            // assertion — a fresh INSERT would renumber them 1,2,3), each pointing at
            // an existing parent rowid through the FK column.
            try ctx.run("INSERT INTO note(id, doc_id, body) VALUES(7, 25, 'note-on-bravo')")
            try ctx.run("INSERT INTO note(id, doc_id, body) VALUES(8, 10, 'note-on-alpha')")
            try ctx.run("INSERT INTO note(id, doc_id, body) VALUES(42, 99, 'note-on-charlie')")
        }
        _ = try Migrator(migrations: [setup]).migrate(temp.db)
        return temp
    }

    @Test
    func `recreate-and-copy adds a column while preserving rowids and FK integrity`() throws {
        let temp = try seededDatabase()
        defer { temp.teardown() }
        let db = temp.db

        // Sanity: the AFTER-INSERT trigger mirrored all three seed rows into the FTS
        // table during v1, under their original rowids.
        #expect(try db.columnInts("SELECT rowid FROM note_fts ORDER BY rowid") == [7, 8, 42])

        // v2: reshape `note` (the FK-owning child) to add a `lang TEXT NOT NULL
        // DEFAULT 'en'` column via recreate-and-copy. The rowid-alias column `id`
        // AND the FK column `doc_id` are carried explicitly, so every row keeps its
        // rowid and its reference into `doc`. The rebuilt table re-declares the FK,
        // which the staged-row copy re-validates against the (untouched) parent.
        let reshape = Migration(version: 2, name: "add note.lang") { ctx throws(DBError) in
            let plan = RecreateAndCopy(
                table: "note",
                stagingTable: "note__staging",
                stagingTableDDL:
                    """
                    CREATE TABLE note__staging(
                      id INTEGER PRIMARY KEY, doc_id INTEGER, body TEXT NOT NULL,
                      lang TEXT NOT NULL DEFAULT 'en')
                    """,
                finalTableDDL:
                    """
                    CREATE TABLE note(
                      id INTEGER PRIMARY KEY,
                      doc_id INTEGER REFERENCES doc ON DELETE RESTRICT,
                      body TEXT NOT NULL,
                      lang TEXT NOT NULL DEFAULT 'en')
                    """,
                // Carry id + doc_id + body from the old shape; default the new column.
                destinationColumns: ["id", "doc_id", "body", "lang"],
                sourceExpressions: ["id", "doc_id", "body", "'en'"],
                ftsSyncTriggerNames: ["note_fts_ai"],
                ftsSyncTriggerDDL: [
                    """
                    CREATE TRIGGER note_fts_ai AFTER INSERT ON note BEGIN
                      INSERT INTO note_fts(rowid, body) VALUES(NEW.id, NEW.body);
                    END
                    """
                ],
                // Rebuild the FTS mirror ONCE: clear it, repopulate from the rebuilt
                // table, and bump the counter so the test can assert "exactly once".
                ftsRebuild: [
                    "DELETE FROM note_fts",
                    "INSERT INTO note_fts(rowid, body) SELECT id, body FROM note",
                    "UPDATE fts_rebuilds SET n = n + 1"
                ])
            try ctx.recreateAndCopy(plan)
        }
        let outcome = try Migrator(
            migrations: [
                Migration(version: 1) { _ throws(DBError) in },  // already applied; skipped
                reshape
            ], forwardOnly: false
        )
        .migrate(db)
        #expect(outcome.appliedVersions == [2])
        #expect(try db.scalarInt("SELECT version FROM schema_version") == 2)

        // (1) Rowids preserved exactly: the reshaped child still holds 7/8/42.
        #expect(try db.columnInts("SELECT id FROM note ORDER BY id") == [7, 8, 42])

        // (2) The new column exists and carries its default for every copied row.
        let langs = try db.prepare("SELECT lang FROM note ORDER BY id").all().map { $0[0] }
        #expect(langs == [.text("en"), .text("en"), .text("en")])
        // Old data preserved through the copy (FK column + body).
        #expect(try db.scalarInt("SELECT doc_id FROM note WHERE id = 7") == 25)
        #expect(try db.prepare("SELECT body FROM note WHERE id = 7").get()?[0] == .text("note-on-bravo"))

        // (3) FK integrity preserved: each child still points at a live parent rowid,
        // and a join across the FK resolves to the original parent row.
        let joined =
            try db.prepare(
                "SELECT note.body, doc.title FROM note JOIN doc ON note.doc_id = doc.id WHERE note.id = 7"
            )
            .get()
        #expect(joined?[0] == .text("note-on-bravo"))
        #expect(joined?[1] == .text("bravo"))

        // (3b) The FK still ENFORCES after the rebuild: deleting a referenced parent is blocked
        // (ON DELETE RESTRICT), proving the rebuilt child re-established the FK + its serving index —
        // recreate-and-copy did not silently drop referential integrity. (ADDB enforces FKs at DELETE
        // time, not INSERT, so there is no dangling-insert rejection to assert here.)
        #expect(throws: DBError.self) {
            try db.prepare("DELETE FROM doc WHERE id = 25").run()
        }

        // (4) The FTS index was rebuilt EXACTLY ONCE (not per-row): the counter is 1,
        // and the mirror holds exactly the three preserved rowids. Had the AFTER
        // triggers stayed live during the bulk copy, the mirror would double up.
        #expect(try db.scalarInt("SELECT n FROM fts_rebuilds") == 1)
        #expect(try db.columnInts("SELECT rowid FROM note_fts ORDER BY rowid") == [7, 8, 42])
        #expect(try db.scalarInt("SELECT COUNT(*) FROM note_fts") == 3)

        // (5) The recreated FTS-sync trigger is live again: a new insert mirrors.
        try db.prepare("INSERT INTO note(id, doc_id, body, lang) VALUES(200, 10, 'delta', 'fr')").run()
        #expect(try db.scalarInt("SELECT COUNT(*) FROM note_fts WHERE rowid = 200") == 1)
    }

    @Test
    func `recreate-and-copy can transform a column value during the copy`() throws {
        let temp = try TempDatabase()
        defer { temp.teardown() }
        let db = temp.db

        let v1 = Migration(version: 1) { ctx throws(DBError) in
            try ctx.run("CREATE TABLE item(id INTEGER PRIMARY KEY, score INTEGER)")
            try ctx.run("INSERT INTO item(id, score) VALUES(5, NULL)")
            try ctx.run("INSERT INTO item(id, score) VALUES(6, 7)")
        }
        _ = try Migrator(migrations: [v1]).migrate(db)

        // v2: make score NOT NULL DEFAULT 0, coalescing existing NULLs during copy.
        let v2 = Migration(version: 2) { ctx throws(DBError) in
            try ctx.recreateAndCopy(
                RecreateAndCopy(
                    table: "item",
                    stagingTable: "item__staging",
                    stagingTableDDL:
                        "CREATE TABLE item__staging(id INTEGER PRIMARY KEY, score INTEGER NOT NULL DEFAULT 0)",
                    finalTableDDL:
                        "CREATE TABLE item(id INTEGER PRIMARY KEY, score INTEGER NOT NULL DEFAULT 0)",
                    destinationColumns: ["id", "score"],
                    sourceExpressions: ["id", "COALESCE(score, 0)"]))
        }
        _ = try Migrator(migrations: [v1, v2], forwardOnly: false).migrate(db)

        #expect(try db.columnInts("SELECT id FROM item ORDER BY id") == [5, 6])
        #expect(try db.scalarInt("SELECT score FROM item WHERE id = 5") == 0)
        #expect(try db.scalarInt("SELECT score FROM item WHERE id = 6") == 7)
    }

    @Test
    func `recreate-and-copy rolls back wholesale when a later step fails`() throws {
        let temp = try seededDatabase()
        defer { temp.teardown() }
        let db = temp.db

        // A plan whose FTS-rebuild references a missing table fails AFTER the
        // staging + copy + index steps have already run. The single migration
        // transaction must roll the ENTIRE reshape back: the old `note` table, its
        // rowids, the FK, and the cursor all stay at v1.
        let broken = Migration(version: 2, name: "broken reshape") { ctx throws(DBError) in
            try ctx.recreateAndCopy(
                RecreateAndCopy(
                    table: "note",
                    stagingTable: "note__staging",
                    stagingTableDDL:
                        """
                        CREATE TABLE note__staging(
                          id INTEGER PRIMARY KEY, doc_id INTEGER, body TEXT NOT NULL, lang TEXT)
                        """,
                    finalTableDDL:
                        """
                        CREATE TABLE note(
                          id INTEGER PRIMARY KEY,
                          doc_id INTEGER REFERENCES doc ON DELETE RESTRICT,
                          body TEXT NOT NULL, lang TEXT)
                        """,
                    destinationColumns: ["id", "doc_id", "body", "lang"],
                    sourceExpressions: ["id", "doc_id", "body", "'en'"],
                    ftsSyncTriggerNames: ["note_fts_ai"],
                    // This statement throws (no such table) only after staging + copy
                    // + final-recreate already succeeded — proving wholesale rollback.
                    ftsRebuild: ["INSERT INTO totally_missing_table(x) VALUES(1)"]))
        }

        #expect(throws: DBError.self) {
            try Migrator(
                migrations: [
                    Migration(version: 1) { _ throws(DBError) in }, broken
                ], forwardOnly: false
            )
            .migrate(db)
        }

        // Cursor unchanged, original child table intact (still the OLD three-column
        // shape), rowids and FK preserved.
        #expect(try db.scalarInt("SELECT version FROM schema_version") == 1)
        #expect(try db.columnInts("SELECT id FROM note ORDER BY id") == [7, 8, 42])
        #expect(try db.prepare("SELECT body FROM note WHERE id = 7").get()?[0] == .text("note-on-bravo"))
        #expect(try db.scalarInt("SELECT doc_id FROM note WHERE id = 7") == 25)
        // The OLD shape had no `lang` column — referencing it must error, proving the
        // new-shape table did not survive the rollback.
        #expect(throws: DBError.self) {
            try db.prepare("SELECT lang FROM note").get()
        }
        // The FTS-sync trigger that was dropped in step (2) is restored by the
        // rollback, so the mirror still reflects the original rows.
        #expect(try db.columnInts("SELECT rowid FROM note_fts ORDER BY rowid") == [7, 8, 42])
    }

    @Test
    func `an empty column mapping is rejected and rolls the transaction back`() throws {
        let temp = try TempDatabase()
        defer { temp.teardown() }
        let db = temp.db

        let v1 = Migration(version: 1) { ctx throws(DBError) in
            try ctx.run("CREATE TABLE t(id INTEGER PRIMARY KEY)")
        }
        _ = try Migrator(migrations: [v1]).migrate(db)

        let bad = Migration(version: 2) { ctx throws(DBError) in
            try ctx.recreateAndCopy(
                RecreateAndCopy(
                    table: "t",
                    stagingTable: "t__staging",
                    stagingTableDDL: "CREATE TABLE t__staging(id INTEGER PRIMARY KEY)",
                    finalTableDDL: "CREATE TABLE t(id INTEGER PRIMARY KEY)",
                    destinationColumns: [],
                    sourceExpressions: []))
        }
        #expect(throws: DBError.self) {
            try Migrator(migrations: [v1, bad], forwardOnly: false).migrate(db)
        }
        // Cursor stayed at 1; the original table is untouched.
        #expect(try db.scalarInt("SELECT version FROM schema_version") == 1)
        #expect(try db.scalarInt("SELECT COUNT(*) FROM t") == 0)
    }
}
