import ADDBCore

/// The `ADSQLFullTextSearch` implementation of ADDBCore's ``FTSEvaluation`` hook:
/// it parses MATCH queries, evaluates them to docids, scores with bm25f, and runs
/// block-max WAND — none of which ADDBCore (which owns only the index) can name.
/// `Database.enableFullTextSearch()` installs the single shared instance; the
/// executor's MATCH row source then resolves queries through it.
final class FTSQueryEvaluator: FTSEvaluation {
    /// One stateless evaluator serves every database (all per-query state lives on
    /// the returned scorer / in locals), mirroring `SQLTriggerEngine.shared`.
    static let shared = FTSQueryEvaluator()

    func match<R: PageResolver>(
        queryBytes: [UInt8], record: Catalog.FTSRecord, resolver: R,
        weights: [Double], needScore: Bool
    ) throws(DBError) -> (docids: [Int64], scorer: (any FTSScoring)?) {
        let query = try FTSQuery.parse(String(decoding: queryBytes, as: UTF8.self))
        let docids = try FTSMatch.evaluate(query, record: record, resolver: resolver)
        // A membership-only MATCH never reads `rank`, so skip building the scorer
        // (resolving every leaf's df/IDF + per-doc frequencies) entirely.
        guard needScore else { return (docids, nil) }
        let global = try FTSIndex.globalStats(resolver, record)
        let prepared = try FTSScorer.PreparedScorer(
            query: query, record: record, resolver: resolver,
            weights: Self.padded(weights, to: record.definition.columns.count), global: global)
        return (docids, PreparedScorerBox(prepared: prepared, resolver: resolver, stats: record.stats))
    }

    func rankedTopK<R: PageResolver>(
        queryBytes: [UInt8], record: Catalog.FTSRecord, resolver: R,
        weights: [Double], k: Int
    ) throws(DBError) -> [(docid: Int64, score: Double)]? {
        let query = try FTSQuery.parse(String(decoding: queryBytes, as: UTF8.self))
        let global = try FTSIndex.globalStats(resolver, record)
        return try FTSWAND.topK(
            query: query, record: record, resolver: resolver,
            weights: Self.padded(weights, to: record.definition.columns.count), global: global, k: k)
    }

    /// Pads `weights` to the FTS column count with 1.0 (the bm25 default), so a
    /// plain `rank` or a partial weight vector scores the trailing columns at unit
    /// weight — matching SQLite FTS5.
    static func padded(_ weights: [Double], to columns: Int) -> [Double] {
        guard weights.count < columns else { return weights }
        return weights + Array(repeating: 1.0, count: columns - weights.count)
    }
}

/// Boxes a query-scoped ``FTSScorer/PreparedScorer`` plus the persistent ascending
/// stats cursor it scores through, behind the storage-defined ``FTSScoring`` so the
/// executor scores each candidate via `score(docid:)` without naming the scorer
/// type. The cursor is reused across the (ascending) candidate docids, so
/// `docLength`'s `seekForward` skips the per-doc root→leaf descent for same-leaf
/// docs — the optimization the executor's local cursor previously held.
final class PreparedScorerBox<R: PageResolver>: FTSScoring {
    private let prepared: FTSScorer.PreparedScorer<R>
    private var statsCursor: Cursor<R>

    init(prepared: FTSScorer.PreparedScorer<R>, resolver: R, stats: TreeHandle) {
        self.prepared = prepared
        self.statsCursor = Cursor(resolver: resolver, tree: stats)
    }

    func score(docid: Int64) throws(DBError) -> Double {
        try prepared.score(docid: docid, statsCursor: &statsCursor)
    }
}

extension Database {
    /// Enables SQL full-text search: installs the query evaluator so `MATCH`,
    /// `rank`, and `bm25(...)` resolve over FTS5 virtual tables. Idempotent; call
    /// once after opening. (The `ftsMatch`/`ftsScore` convenience APIs work without
    /// it — they call the query layer directly.)
    public func enableFullTextSearch() {
        installFTSEvaluator(FTSQueryEvaluator.shared)
    }
}
