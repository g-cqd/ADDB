import ADFCore
public import ADSQLModel
import Synchronization

/// A per-snapshot cache of every document's total length `D = Σ_c fieldLengths` —
/// the single bm25 datum the ranked scorer needs for each matched document.
///
/// A broad-term ranked query (`view`, `button`) scores tens of thousands of
/// documents, and the point read this replaces cost one stats-tree lookup PER
/// document: a root→leaf descent whose page resolutions dispatch through the
/// `PageResolver` witness — the cost a profile of the read path attributed ~two
/// thirds of its time to. Loading every length once, by a single ascending scan
/// of the stats tree, turns `length(docid)` into an O(1) array index: no B-tree
/// descent, no `resolvePage`, no generic dispatch on the per-document hot path.
///
/// The table is keyed by the FTS record's committed tree roots. A committed B+tree
/// is copy-on-write, so a new generation (after a write commits) gets fresh roots
/// and the key self-invalidates; a read snapshot's roots are stable, so a
/// read-heavy corpus loads exactly once. The summed lengths are bit-identical to
/// the per-document decode `docLength` performs, so bm25 scores are unchanged.
@_spi(ADDBEngine) public struct FTSLengthTable: Sendable {
    @usableFromInline let lengths: [Double]
    @usableFromInline init(lengths: [Double]) { self.lengths = lengths }

    /// `D` for `docid`, O(1). A gap/absent docid returns 0 — it is never a matched
    /// document (only indexed docids carry postings), so it is never scored.
    @inline(__always)
    @_spi(ADDBEngine) public func length(_ docid: Int64) -> Double {
        let index = Int(docid)
        return (index >= 0 && index < lengths.count) ? lengths[index] : 0
    }
}

@_spi(ADDBEngine) public enum FTSLengthCache {
    private struct Key: Hashable {
        /// Identity of the snapshot's page source — a per-database object. Distinct
        /// databases reuse low page numbers, so the tree roots alone are NOT unique
        /// across databases (a real collision in tests, which open many small corpora).
        let source: ObjectIdentifier
        let stats: UInt64
        let dict: UInt64
        let postings: UInt64
    }

    /// Global, bounded. Keyed by the page-source identity plus the record's three
    /// committed roots — unique per (database, snapshot). Copy-on-write gives each
    /// committed generation fresh roots, so a write invalidates the key; bounded to a
    /// handful of generations so a write-churning database cannot grow it without limit.
    private static let cache = Mutex<[Key: FTSLengthTable]>([:])
    private static let capacity = 32

    /// The length table for `record` under `resolver`'s snapshot: a cache hit, or a
    /// one-time load (a full ascending scan of the stats tree). Only the committed read
    /// path (`CommittedResolver`) is cached — it is the only resolver that scores, and
    /// its page source gives a database-unique key. Any other resolver loads fresh.
    @_spi(ADDBEngine) public static func table(
        _ resolver: some PageResolver, _ record: Catalog.FTSRecord
    ) throws(DBError) -> FTSLengthTable {
        guard let source = (resolver as? CommittedResolver).map({ ObjectIdentifier($0.source) })
        else { return try load(resolver, record) }
        let key = Key(
            source: source, stats: record.stats.rootPage, dict: record.dict.rootPage,
            postings: record.postings.rootPage)
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let table = try load(resolver, record)
        cache.withLock { store in
            if store.count >= capacity { store.removeAll(keepingCapacity: true) }
            store[key] = table
        }
        return table
    }

    /// One ascending scan of the stats tree into a docid-indexed length array. The
    /// `[0x00]` global-aggregates row has no 8-byte rowid suffix, so `rowid(fromSuffixOf:)`
    /// rejects it; every other row is `rowKey(docid) → forward record`, whose leading
    /// field-length varints sum to `D` (the same bytes `docLength` decodes).
    private static func load(
        _ resolver: some PageResolver, _ record: Catalog.FTSRecord
    ) throws(DBError) -> FTSLengthTable {
        var maxDocid: Int64 = -1
        var tail = Cursor(resolver: resolver, tree: record.stats)
        if try tail.move(to: .last), let key = try tail.currentKey() {
            maxDocid = key.withUnsafeBytes { unsafe KeyCodec.rowid(fromSuffixOf: $0) } ?? -1
        }
        guard maxDocid >= 0 else { return FTSLengthTable(lengths: []) }

        var lengths = [Double](repeating: 0, count: Int(maxDocid) + 1)
        var cursor = Cursor(resolver: resolver, tree: record.stats)
        if try cursor.move(to: .first) {
            repeat {
                guard let keyBytes = try cursor.currentKey(),
                    let docid = keyBytes.withUnsafeBytes({ unsafe KeyCodec.rowid(fromSuffixOf: $0) }),
                    docid >= 0, docid <= maxDocid
                else { continue }
                let total: Double =
                    unsafe try cursor.withCurrentValueBytes { (raw) throws(DBError) -> Double in
                        var offset = 0
                        guard let fieldCount = unsafe Varint.read(raw, &offset) else { return 0 }
                        var sum = 0.0
                        for _ in 0 ..< fieldCount {
                            guard let fieldLength = unsafe Varint.read(raw, &offset) else { break }
                            sum += Double(fieldLength)
                        }
                        return sum
                    } ?? 0
                lengths[Int(docid)] = total
            } while try cursor.next()
        }
        return FTSLengthTable(lengths: lengths)
    }
}
