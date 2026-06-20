@_spi(ADDBEngine) public import ADDBCore
import ADSQL
public import ADSQLModel

/// A column-shape change expressed as recreate-and-copy: build the new-shape
/// table, copy the rows across a column mapping (preserving rowids), recreate
/// the dependent objects, and swap the new table into the old one's place — all
/// inside the migrator's single write transaction.
///
/// ADDB has no `ALTER TABLE`; its COW-B+tree / single-writer / MVCC design makes
/// this recreate-and-copy the natural, transactional way to change a column
/// layout. Because the whole plan runs in one transaction, a crash leaves the
/// table fully old or fully new.
///
/// ## Rowid preservation
/// Foreign keys reference a parent through its rowid (the INTEGER PRIMARY KEY
/// alias), so the copy MUST carry the rowid column explicitly: list the
/// rowid-alias column first in both ``destinationColumns`` and
/// ``sourceExpressions`` (e.g. destination `["id", …]`, source `["id", …]`).
/// The `INSERT … SELECT` then lands each row under its original rowid, and FK
/// references into this table stay valid.
///
/// ## FTS / trigger edge case
/// If AFTER-triggers keep an FTS index in step with this table, a bulk
/// `INSERT … SELECT` would fire them once per row (quadratic). Name those
/// triggers in ``ftsSyncTriggerNames`` and the rebuild DDL in ``ftsRebuild``:
/// the plan drops the triggers before the copy, performs the copy once, runs the
/// rebuild once, then recreates the triggers — all in the same transaction.
///
/// ## Inbound foreign keys (current limitation)
/// This plan reshapes a SINGLE table by dropping and recreating it. The engine
/// blocks `DROP TABLE` on a table that still has inbound-FK children, and its
/// `PRAGMA foreign_keys` is a no-op (FKs are always enforced) — so the SQLite
/// "disable FKs, rebuild, re-enable" recipe is unavailable. Consequently:
///   * Reshaping the FK-OWNING side (a child, or any table no one references)
///     works directly — carry the FK column in the mapping and the rebuilt table
///     re-declares the constraint, which the copy re-validates against the
///     untouched parent.
///   * Reshaping a PARENT that has inbound-FK children additionally requires
///     rebuilding those children (drop child → rebuild parent → rebuild child,
///     all in the one transaction, every rowid carried). That multi-table
///     orchestration is **not yet supported** by this single-table plan; a future
///     `recreateAndCopyParent` (or multi-table) variant would express it.
public struct RecreateAndCopy: Sendable {
    /// The table being reshaped (its current name, which is also the final name
    /// the new table takes).
    public let table: String

    /// DDL creating the new-shape table under a *staging* name (see
    /// ``stagingTable``). Use the exact staging name in this statement's
    /// `CREATE TABLE`; the plan rewrites nothing.
    ///
    /// The plan needs the staging step because ADDB lacks `ALTER TABLE RENAME`:
    /// it cannot build directly into the final name while the old table still
    /// occupies it, nor copy from the old table after dropping it. So it stages
    /// the reshaped rows, drops the old table, recreates the table under its
    /// final name with the same new shape (``finalTableDDL``), and copies the
    /// staged rows across.
    public let stagingTableDDL: String

    /// The staging table's name (must match the name used in
    /// ``stagingTableDDL``). Dropped before the plan returns.
    public let stagingTable: String

    /// DDL creating the table under its *final* (original) name with the new
    /// shape. Identical column layout to ``stagingTableDDL`` but named ``table``.
    public let finalTableDDL: String

    /// Destination column list for the old → staging copy. Must include the
    /// rowid-alias column. Order matches ``sourceExpressions``.
    public let destinationColumns: [String]

    /// Select expressions read from the OLD table, positionally matching
    /// ``destinationColumns``. Plain column names copy a value through; an
    /// expression (`"COALESCE(score, 0)"`, `"x || y"`) transforms it. Must
    /// include the rowid-alias source.
    public let sourceExpressions: [String]

    /// Indexes to recreate on the final table (full `CREATE INDEX …` DDL).
    /// Dropping the old table drops its indexes, so any the new shape still
    /// needs are listed here and recreated after the swap.
    public let dependentIndexes: [String]

    /// FTS-sync AFTER-trigger names to DROP before the bulk copy (so they do not
    /// fire per row) and recreate after. Empty when the table has no FTS mirror.
    public let ftsSyncTriggerNames: [String]

    /// Full `CREATE TRIGGER …` DDL recreating the triggers named in
    /// ``ftsSyncTriggerNames``, run after the FTS rebuild. Order preserved.
    public let ftsSyncTriggerDDL: [String]

    /// Statements that rebuild the FTS index once after the copy (e.g. a
    /// `DELETE FROM fts` followed by an `INSERT INTO fts(rowid, …) SELECT …`).
    /// Run exactly once, after the staged rows reach the final table and before
    /// the triggers are recreated. Empty when there is no FTS mirror.
    public let ftsRebuild: [String]

    public init(
        table: String,
        stagingTable: String,
        stagingTableDDL: String,
        finalTableDDL: String,
        destinationColumns: [String],
        sourceExpressions: [String],
        dependentIndexes: [String] = [],
        ftsSyncTriggerNames: [String] = [],
        ftsSyncTriggerDDL: [String] = [],
        ftsRebuild: [String] = []
    ) {
        self.table = table
        self.stagingTable = stagingTable
        self.stagingTableDDL = stagingTableDDL
        self.finalTableDDL = finalTableDDL
        self.destinationColumns = destinationColumns
        self.sourceExpressions = sourceExpressions
        self.dependentIndexes = dependentIndexes
        self.ftsSyncTriggerNames = ftsSyncTriggerNames
        self.ftsSyncTriggerDDL = ftsSyncTriggerDDL
        self.ftsRebuild = ftsRebuild
    }

    /// Pre-flight validation independent of the database, so an obviously
    /// malformed plan fails before opening the transaction.
    func validate() throws(MigrationError) {
        guard !destinationColumns.isEmpty else {
            throw MigrationError.emptyColumnMapping(table: table)
        }
        guard destinationColumns.count == sourceExpressions.count else {
            throw MigrationError.columnMappingArityMismatch(
                table: table,
                destinationCount: destinationColumns.count,
                sourceCount: sourceExpressions.count)
        }
    }
}

extension MigrationContext {
    /// Performs a ``RecreateAndCopy`` inside the migration transaction.
    ///
    /// Sequence (one transaction, all-or-nothing):
    /// 1. validate the plan (arity / non-empty mapping);
    /// 2. drop the FTS-sync triggers (so the bulk copy does not fire them per row);
    /// 3. `CREATE` the staging table and `INSERT … SELECT` the mapped rows from
    ///    the old table, preserving rowids;
    /// 4. `DROP` the old table (and its indexes);
    /// 5. `CREATE` the final table under the original name, then copy the staged
    ///    rows into it (preserving rowids), then `DROP` the staging table;
    /// 6. recreate dependent indexes;
    /// 7. run the FTS rebuild once;
    /// 8. recreate the FTS-sync triggers.
    public func recreateAndCopy(_ plan: RecreateAndCopy) throws(DBError) {
        // (1) Plan-shape validation surfaces as a DBError so the body's single
        // `throws(DBError)` contract holds and a bad plan still rolls the txn back.
        do {
            try plan.validate()
        } catch {
            throw DBError.invalidDefinition(error.message)
        }

        // (2) Suspend FTS-sync triggers: a per-row fire across a bulk copy is
        // quadratic. IF EXISTS so a partial/idempotent re-run is safe.
        for trigger in plan.ftsSyncTriggerNames {
            try run("DROP TRIGGER IF EXISTS \(trigger)")
        }

        // (3) Stage the reshaped rows, carrying rowids via the explicit mapping.
        try run(plan.stagingTableDDL)
        let destList = plan.destinationColumns.joined(separator: ", ")
        let srcList = plan.sourceExpressions.joined(separator: ", ")
        try run(
            "INSERT INTO \(plan.stagingTable)(\(destList)) SELECT \(srcList) FROM \(plan.table)")

        // (4) Drop the old table. Its indexes and triggers go with it; the FTS-sync
        // triggers were already dropped in (2), the rest are recreated below.
        try run("DROP TABLE \(plan.table)")

        // (5) Recreate under the final name with the new shape, then move the staged
        // rows across (same shape now, so the column list is the destination list,
        // and the source is the matching column names from staging — rowids carried
        // by the rowid-alias column that appears in `destinationColumns`).
        try run(plan.finalTableDDL)
        try run(
            "INSERT INTO \(plan.table)(\(destList)) SELECT \(destList) FROM \(plan.stagingTable)")
        try run("DROP TABLE \(plan.stagingTable)")

        // (6) Recreate dependent indexes on the final table.
        for index in plan.dependentIndexes {
            try run(index)
        }

        // (7) Rebuild the FTS index ONCE (triggers are still suspended).
        for statement in plan.ftsRebuild {
            try run(statement)
        }

        // (8) Recreate the FTS-sync triggers so ongoing DML keeps the index in step.
        for ddl in plan.ftsSyncTriggerDDL {
            try run(ddl)
        }
    }
}
