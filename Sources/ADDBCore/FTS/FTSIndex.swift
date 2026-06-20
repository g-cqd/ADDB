import ADFCore
public import ADSQLModel

/// FTS index build + maintenance. Drives a tokenized document into
/// the three per-FTS-table B+trees the catalog `FTSRecord` owns:
///
/// - **dict**: `term → varint df` (df == posting-list length). Gives
/// prefix-term enumeration + IDF without decoding postings.
/// - **postings**: a term's block-compressed posting list (`FTSPostings`),
/// stored **one fixed-size block per key**: key `varint(len)||term||
/// bigEndian(blockNo)`, value a single-block `FTSPostings` payload (≤128
/// docs). Appending a document rewrites only the last block (O(blockSize))
/// instead of the whole list (O(list)), turning a bulk build from O(n²) into
/// O(n). Blocks stay packed (all full but the last), so `blockNo = (df-1)/128`
/// and a term's blocks are `0...lastNo` — no separate segment directory.
/// - **stats**: `rowKey(docid) → forward record` (field lengths + the doc's
/// distinct terms — the delete companion) and `[0x00] → global aggregates`.
///
/// Readers reconstitute a term's whole list by unioning its block-keys
/// (`postingsValue`), so `postings`/MATCH/WAND/the scorer are unchanged.
@_spi(ADDBEngine) public enum FTSIndex {
    /// Tokens longer than this are skipped (kept out of the term keyspace); they
    /// still count toward field length. B+tree keys are bounded by `maxKeySize`.
    static let maxTermBytes = 256
    /// Global-aggregates key. One byte sorts before every 8-byte `rowKey`, so a
    /// `move(to:.last)` on the stats tree lands on the largest docid.
    static let globalKey: [UInt8] = [0x00]

    // MARK: - Build

    /// One document buffered in the transaction-scoped FTS memtable. `ftsAdd`
    /// appends these; the flush (`addBatch`) writes them coalesced.
    struct PendingDoc: Sendable {
        let docid: Int64
        let columnTexts: [String]
    }

    /// Per-term, per-document accumulator used while tokenizing one document in a batch. A *reference
    /// type* on purpose: the hot per-token writes (`fieldTFs[col] += 1`, `positions[col].append(...)`)
    /// mutate its uniquely-referenced arrays in place. The previous value-tuple-in-a-dictionary form
    /// (`termInfo[term]!.positions[col].append(...)`) re-hashed the term up to three times per token
    /// and could copy-on-write the nested `[[UInt32]]` on every append; a class fetched once per token
    /// removes both costs. Lives only for the duration of one `addBatch` call.
    private final class TermAccumulator {
        var fieldTFs: [UInt32]
        var positions: [[UInt32]]
        init(columns: Int) {
            fieldTFs = [UInt32](repeating: 0, count: columns)
            positions = Array(repeating: [UInt32](), count: columns)
        }
    }

    /// Indexes a BATCH of documents in one coalesced pass (the memtable flush).
    /// Tokenizes every doc, accumulates `term → [posting]` across the whole batch,
    /// then merges each term's postings into the tree ONCE — O(distinct terms)
    /// block writes instead of O(docs × terms/doc), the build-throughput win.
    /// `docs` need not be docid-sorted; a docid already on disk or repeated within
    /// the batch is rejected (mirrors the per-doc invariant) — but the error now
    /// surfaces at flush (the next same-table read or commit) and so aborts the
    /// whole transaction rather than the individual INSERT statement.
    static func addBatch(
        _ ctx: TxnContext, record: inout Catalog.FTSRecord, docs: [PendingDoc]
    ) throws(DBError) {
        guard !docs.isEmpty else { return }
        let columns = record.definition.columns.count
        let storePositions = record.definition.detail != .none
        let tokenizer = try FTSTokenizerFactory.make(record.definition.tokenize)

        var stats = record.stats
        var termPostings: [[UInt8]: [FTSPosting]] = [:]
        var forwards: [(docid: Int64, fieldLengths: [UInt32], terms: [[UInt8]])] = []
        forwards.reserveCapacity(docs.count)
        var seen = Set<Int64>()
        seen.reserveCapacity(docs.count)
        for doc in docs {
            guard seen.insert(doc.docid).inserted,
                try Relation.getBytes(ctx, stats, key: KeyCodec.rowKey(doc.docid)) == nil
            else {
                throw DBError.invalidDefinition(
                    "fts \(record.definition.name): docid \(doc.docid) already indexed")
            }
            var fieldLengths = [UInt32](repeating: 0, count: columns)
            var termInfo: [[UInt8]: TermAccumulator] = [:]
            for column in 0 ..< min(columns, doc.columnTexts.count) {
                try tokenizer.tokenize(Array(doc.columnTexts[column].utf8)) { (token) throws(DBError) in
                    fieldLengths[column] += 1
                    guard !token.term.isEmpty, token.term.count <= maxTermBytes else { return }
                    // One hash lookup per token; the class reference then mutates its own
                    // uniquely-referenced arrays in place (no dictionary write-back, no CoW).
                    let accum: TermAccumulator
                    if let existing = termInfo[token.term] {
                        accum = existing
                    } else {
                        accum = TermAccumulator(columns: columns)
                        termInfo[token.term] = accum
                    }
                    accum.fieldTFs[column] += 1
                    if storePositions { accum.positions[column].append(UInt32(token.position)) }
                }
            }
            for (term, info) in termInfo {
                termPostings[term, default: []]
                    .append(
                        FTSPosting(
                            docid: doc.docid, fieldTFs: info.fieldTFs,
                            positions: storePositions ? info.positions : []))
            }
            forwards.append((doc.docid, fieldLengths, Array(termInfo.keys)))
        }

        var dict = record.dict
        var postings = record.postings
        try writeTermPostings(
            ctx, dict: &dict, postings: &postings, termPostings: termPostings,
            columns: columns, storePositions: storePositions)

        var global = try readGlobal(ctx, stats, columns: columns)
        for fwd in forwards {
            try Relation.putBytes(
                ctx, &stats, key: KeyCodec.rowKey(fwd.docid),
                value: encodeForward(fieldLengths: fwd.fieldLengths, terms: fwd.terms))
            global.docCount += 1
            for column in 0 ..< min(columns, fwd.fieldLengths.count) {
                global.totalFieldLengths[column] += UInt64(fwd.fieldLengths[column])
            }
        }
        try Relation.putBytes(ctx, &stats, key: globalKey, value: global.encode())

        record.dict = dict
        record.postings = postings
        record.stats = stats
    }

    /// Writes one batch's per-term posting additions: a fresh packed list for a new
    /// term, an O(batch) tail-append when the additions are all newer than the last
    /// stored docid, else a full read-merge-repack. Updates each term's DF in `dict`.
    private static func writeTermPostings(
        _ ctx: TxnContext, dict: inout TreeHandle, postings: inout TreeHandle,
        termPostings: [[UInt8]: [FTSPosting]], columns: Int, storePositions: Bool
    ) throws(DBError) {
        for (term, additions) in termPostings {
            let sorted = additions.sorted { $0.docid < $1.docid }
            let oldDF = try documentFrequency(ctx, dict, term: term)
            let finalCount: Int
            if oldDF == 0 {
                try writePacked(ctx, &postings, term: term, sorted, columns: columns, positions: storePositions)
                finalCount = sorted.count
            } else {
                let lastNo = blockNo(forDF: oldDF)
                let lastBlock = try readBlock(
                    ctx, postings, term: term, blockNo: lastNo, columns: columns, positions: storePositions)
                if let lastDocid = lastBlock.last?.docid, let firstNew = sorted.first?.docid,
                    firstNew > lastDocid
                {
                    // Ascending append (the bulk-build common case): re-pack only the last
                    // block plus the appended postings into blocks from `lastNo` — O(batch),
                    // never re-reading earlier blocks, so a multi-batch build stays linear.
                    let combined = lastBlock + sorted
                    var no = lastNo
                    var start = 0
                    while start < combined.count {
                        let end = min(start + FTSPostings.blockSize, combined.count)
                        try writeBlock(
                            ctx, &postings, term: term, blockNo: no, Array(combined[start ..< end]),
                            layout: BlockLayout(columns: columns, positions: storePositions))
                        no += 1
                        start = end
                    }
                    finalCount = Int(oldDF) + sorted.count
                } else {
                    // Out-of-order: read the whole list, merge, re-pack.
                    let merged = mergePostings(
                        try fullList(ctx, postings, term: term, columns: columns, positions: storePositions),
                        sorted)
                    try rewritePacked(
                        ctx, &postings, term: term, oldLastNo: lastNo, merged,
                        layout: BlockLayout(columns: columns, positions: storePositions))
                    finalCount = merged.count
                }
            }
            try Relation.putBytes(ctx, &dict, key: term, value: encodeDF(UInt64(finalCount)))
        }
    }

    @discardableResult
    static func remove(
        _ ctx: TxnContext, record: inout Catalog.FTSRecord, docid: Int64
    ) throws(DBError) -> Bool {
        let columns = record.definition.columns.count
        let storePositions = record.definition.detail != .none
        let docKey = KeyCodec.rowKey(docid)
        guard let forwardBytes = try Relation.getBytes(ctx, record.stats, key: docKey) else {
            return false
        }
        let forward = try decodeForward(forwardBytes)

        var dict = record.dict
        var postings = record.postings
        var stats = record.stats
        for term in forward.terms {
            let oldDF = try documentFrequency(ctx, dict, term: term)
            guard oldDF > 0 else { continue }
            let lastNo = blockNo(forDF: oldDF)
            var list = try fullList(
                ctx, postings, term: term, columns: columns, positions: storePositions)
            list.removeAll { $0.docid == docid }
            // Drop the term's existing blocks, then re-pack what remains.
            for no in 0 ... lastNo { _ = try Relation.deleteBytes(ctx, &postings, key: blockKey(term, no)) }
            if list.isEmpty {
                _ = try Relation.deleteBytes(ctx, &dict, key: term)
            } else {
                try writePacked(
                    ctx, &postings, term: term, list, columns: columns, positions: storePositions)
                try Relation.putBytes(ctx, &dict, key: term, value: encodeDF(UInt64(list.count)))
            }
        }
        _ = try Relation.deleteBytes(ctx, &stats, key: docKey)
        var global = try readGlobal(ctx, stats, columns: columns)
        if global.docCount > 0 { global.docCount -= 1 }
        for column in 0 ..< min(columns, forward.fieldLengths.count) {
            let length = UInt64(forward.fieldLengths[column])
            global.totalFieldLengths[column] =
                global.totalFieldLengths[column] >= length ? global.totalFieldLengths[column] - length : 0
        }
        try Relation.putBytes(ctx, &stats, key: globalKey, value: global.encode())

        record.dict = dict
        record.postings = postings
        record.stats = stats
        return true
    }

    /// Clears the whole index (`'delete-all'`): frees the three trees and resets
    /// the record's handles to empty. Global/per-doc stats vanish with the trees.
    static func removeAll(_ ctx: TxnContext, record: inout Catalog.FTSRecord) throws(DBError) {
        try Relation.freeTree(ctx, handle: record.dict)
        try Relation.freeTree(ctx, handle: record.postings)
        try Relation.freeTree(ctx, handle: record.stats)
        record.dict = .empty
        record.postings = .empty
        record.stats = .empty
    }

    /// Next auto docid: max docid in the stats tree + 1 (1 when empty). The global
    /// `[0x00]` row sorts first, so the last key — when present — is a doc key.
    static func nextRowid(_ resolver: some PageResolver, statsHandle: TreeHandle) throws(DBError) -> Int64 {
        var cursor = Cursor(resolver: resolver, tree: statsHandle)
        var next: Int64 = 1
        if try cursor.move(to: .last) {
            let last: Int64?? = unsafe try cursor.withCurrent { (key, _) throws(DBError) in
                unsafe KeyCodec.rowid(fromSuffixOf: key)
            }
            if let maxDocid = last ?? nil, maxDocid >= 0, maxDocid < Int64.max { next = maxDocid + 1 }
        }
        return next
    }

    // MARK: - Reads (tests + /)

    @_spi(ADDBEngine) public static func postings(
        _ resolver: some PageResolver, _ record: Catalog.FTSRecord, term: [UInt8]
    ) throws(DBError) -> [FTSPosting]? {
        guard let value = try postingsValue(resolver, record, term: term) else { return nil }
        return try FTSPostings.decode(
            value, columns: record.definition.columns.count,
            storePositions: record.definition.detail != .none)
    }

    /// A term's whole posting list reconstituted as a single multi-block
    /// `FTSPostings` value, unioning its `0...lastNo` block-keys. nil when the term
    /// is absent. Readers (`postings`, MATCH, WAND, the scorer) consume this so
    /// they are oblivious to the block-per-key storage.
    @_spi(ADDBEngine) public static func postingsValue(
        _ resolver: some PageResolver, _ record: Catalog.FTSRecord, term: [UInt8]
    ) throws(DBError) -> [UInt8]? {
        // One range scan over the term's block-keys, reassembled into the single
        // multi-block value. Each block value is `varint(1) || block`; the per-block
        // count prefix is dropped and the running total re-emitted at the head.
        // Zero-copy in: `value` is the mapped page span, so `Array(value.dropFirst())`
        // copies the body out once directly — no longer a full `copyValue` of the
        // block followed by a second `dropFirst` copy. The slice is consumed here
        // and `bodies` owns its contents; the span never escapes the call.
        var bodies: [[UInt8]] = []
        try forEachBlockValue(resolver, record.postings, term: term) { value in
            unsafe bodies.append(Array(value.dropFirst()))
        }
        guard !bodies.isEmpty else { return nil }
        let bodyBytes = bodies.reduce(0) { $0 + $1.count }
        var combined: [UInt8] = []
        combined.reserveCapacity(Varint.maxEncodedLength + bodyBytes)
        Varint.append(UInt64(bodies.count), to: &combined)
        for body in bodies { combined.append(contentsOf: body) }
        return combined
    }

    /// Docids only for `term` — unions the term's block-keys, decoding just docids
    /// from each block and skipping its TF/position payload (membership fast
    /// path). nil when the term is absent.
    @_spi(ADDBEngine) public static func docids(
        _ resolver: some PageResolver, _ record: Catalog.FTSRecord, term: [UInt8]
    ) throws(DBError) -> [Int64]? {
        var ids: [Int64] = []
        var present = false
        try forEachBlockValue(resolver, record.postings, term: term) { (value) throws(DBError) in
            present = true
            // `decodeDocids` consumes a `[UInt8]`; rebuild it from the span (same cost
            // as the prior per-block `copyValue`, never worse) and consume it here.
            ids.append(contentsOf: try FTSPostings.decodeDocids(singleBlock: unsafe Array(value)))
        }
        return present ? ids : nil
    }

    @_spi(ADDBEngine) public static func documentFrequency(
        _ resolver: some PageResolver, _ record: Catalog.FTSRecord, term: [UInt8]
    ) throws(DBError) -> UInt64 {
        try documentFrequency(resolver, record.dict, term: term)
    }

    @_spi(ADDBEngine) public static func globalStats(
        _ resolver: some PageResolver, _ record: Catalog.FTSRecord
    ) throws(DBError) -> FTSGlobalStats {
        try readGlobal(resolver, record.stats, columns: record.definition.columns.count)
    }

    static func docStats(
        _ resolver: some PageResolver, _ record: Catalog.FTSRecord, docid: Int64
    ) throws(DBError) -> FTSDocStats? {
        guard let bytes = try Relation.getBytes(resolver, record.stats, key: KeyCodec.rowKey(docid)) else {
            return nil
        }
        return FTSDocStats(fieldLengths: try decodeForward(bytes).fieldLengths)
    }

    /// The document's total length `D = Σ_c fieldLengths` — the only forward-record
    /// datum bm25 scoring needs — read through a PERSISTENT ascending cursor on the
    /// stats tree. `seekForward` skips the root→leaf descent whenever `docid` lies in
    /// the cursor's current leaf, so scoring documents in ascending docid order
    /// (every ranked path does) pays ~one descent per leaf instead of one per
    /// document — the dominant ranked cost the point-read incurred. It decodes
    /// ONLY the leading field-length varints (never the doc's term list), zero-copy.
    /// nil when the doc has no stats row (absent/removed). Bit-identical `D` to the
    /// prior point read. Hot path: one call per scored document.
    @_spi(ADDBEngine) public static func docLength<R: PageResolver>(
        _ statsCursor: inout Cursor<R>, docid: Int64
    ) throws(DBError) -> Double? {
        let key = KeyCodec.rowKey(docid)
        let found = try key.withUnsafeBytesThrowing { raw throws(DBError) in
            unsafe try statsCursor.seekForward(raw)
        }
        guard found else { return nil }
        return unsafe try statsCursor.withCurrentValueBytes { (raw) throws(DBError) -> Double in
            var offset = 0
            guard let fieldCount = unsafe Varint.read(raw, &offset) else {
                throw DBError.integrityFailure("fts forward: missing field count")
            }
            var total = 0.0
            for _ in 0 ..< fieldCount {
                guard let length = unsafe Varint.read(raw, &offset) else {
                    throw DBError.integrityFailure("fts forward: truncated field length")
                }
                total += Double(length)
            }
            return total
        }
    }

    /// Every dictionary term that starts with `prefix` (for `foo*` queries). The
    /// dict tree is keyed by raw term bytes, so a seek + ascending walk while the
    /// key still carries the prefix enumerates the range.
    @_spi(ADDBEngine) public static func termsMatchingPrefix(
        _ resolver: some PageResolver, _ record: Catalog.FTSRecord, prefix: [UInt8]
    ) throws(DBError) -> [[UInt8]] {
        var terms: [[UInt8]] = []
        var cursor = Cursor(resolver: resolver, tree: record.dict)
        var positioned = try prefix.withUnsafeBytesThrowing { raw throws(DBError) in
            _ = unsafe try cursor.seek(raw)
            return cursor.isValid
        }
        while positioned {
            let proceed: Bool? = unsafe try cursor.withCurrent { (key, _) throws(DBError) in
                let term = unsafe [UInt8](key)
                guard term.starts(with: prefix) else { return false }
                terms.append(term)
                return true
            }
            guard proceed == true else { break }
            positioned = try cursor.next()
        }
        return terms
    }
}
