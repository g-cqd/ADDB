/// A per-document relevance scorer prepared for one MATCH query, returned by an
/// ``FTSEvaluation``. It holds whatever per-query state the implementation needs
/// (resolved query leaves, a reused stats cursor) so the executor's per-document
/// loop is a lookup, not a re-resolution. Used transiently within one SELECT
/// execution, on the thread that created it — not `Sendable`.
package protocol FTSScoring: AnyObject {
    /// The (negated) bm25f relevance of `docid` for the prepared query — the same
    /// value the score-all path produces, and 0 for a document the query does not
    /// positively match.
    func score(docid: Int64) throws(DBError) -> Double
}

/// The storage layer's hook into the full-text-search *query* language. ADDBCore
/// owns the FTS index (postings, statistics, tokenizers — all written during
/// DML); the query language (MATCH parsing, bm25f scoring, block-max WAND) is a
/// superset that lives in the opt-in `ADSQLFullTextSearch` module. That module
/// implements this protocol and installs it via `Database.enableFullTextSearch()`,
/// so the executor's MATCH row source evaluates queries without this layer ever
/// naming a query-language type. This inverts the dependency exactly as
/// ``TriggerFiring`` does for triggers; FTS differs only in that its evaluator
/// lives *above* the SQL engine, so registration is explicit rather than riding
/// `prepare`.
package protocol FTSEvaluation: Sendable {
    /// The membership docids (ascending) of the MATCH `queryBytes` over `record`,
    /// plus — only when `needScore` — a per-document scorer prepared for the same
    /// query (a membership-only MATCH never builds a scorer). The query is parsed
    /// once for both. `weights` are the plan's per-column bm25 weights; the
    /// implementation pads them to the FTS column count.
    func match<R: PageResolver>(
        queryBytes: [UInt8], record: Catalog.FTSRecord, resolver: R,
        weights: [Double], needScore: Bool
    ) throws(DBError) -> (docids: [Int64], scorer: (any FTSScoring)?)

    /// Block-max WAND ranked top-k for the MATCH `queryBytes`: the top-`k`
    /// `(docid, score)` in final ranked order (most relevant first, ties by
    /// ascending docid), or **nil to fall back** to ``match`` + score-all (an
    /// ineligible query shape or a degenerate corpus). `k` is offset+limit.
    func rankedTopK<R: PageResolver>(
        queryBytes: [UInt8], record: Catalog.FTSRecord, resolver: R,
        weights: [Double], k: Int
    ) throws(DBError) -> [(docid: Int64, score: Double)]?
}
