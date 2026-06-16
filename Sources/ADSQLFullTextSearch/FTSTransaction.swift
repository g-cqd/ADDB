public import ADDBCore

extension WriteTxn {
    /// Evaluates a MATCH query string against an FTS table → matching docids
    /// (ascending). Boolean membership only; ranking is the `ftsScore` / SQL
    /// `rank` surface. A convenience over the query layer for tests and tools; the
    /// SQL `MATCH` surface goes through the executor's row source instead.
    public func ftsMatch(_ table: String, _ query: String) throws(DBError) -> [Int64] {
        try FTSMatch.evaluate(FTSQuery.parse(query), record: ftsRecord(table), resolver: ctx)
    }

    /// The bm25f score of `docid` for a MATCH query string, under per-column
    /// `weights` (defaulting to all-ones for plain bm25). Negative: smaller is more
    /// relevant. Exposed for the scorer tests; the SQL `rank`/`bm25` surface
    /// computes the same score in the executor.
    public func ftsScore(
        _ table: String, _ query: String, weights: [Double]? = nil, docid: Int64
    ) throws(DBError) -> Double {
        let record = try ftsRecord(table)
        let columns = record.definition.columns.count
        let resolved = weights ?? [Double](repeating: 1.0, count: columns)
        return try FTSScorer.score(
            FTSQuery.parse(query), record: record, resolver: ctx, docid: docid,
            weights: resolved, global: try FTSIndex.globalStats(ctx, record))
    }
}
