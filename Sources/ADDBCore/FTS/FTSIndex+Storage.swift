import ADFCore
import ADSQLModel

/// FTSIndex on-disk format layer: block-per-key posting storage (read / write /
/// re-pack) plus the document-frequency, global-stats, and forward-index codecs.
/// Split from `FTSIndex.swift` to keep the enum body within the gate.
extension FTSIndex {
    /// Merges two docid-ascending posting lists into one (stable on equal docids,
    /// which the batch's dup-check rules out anyway).
    static func mergePostings(_ a: [FTSPosting], _ b: [FTSPosting]) -> [FTSPosting] {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        var out: [FTSPosting] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i].docid <= b[j].docid {
                out.append(a[i])
                i += 1
            } else {
                out.append(b[j])
                j += 1
            }
        }
        if i < a.count { out.append(contentsOf: a[i...]) }
        if j < b.count { out.append(contentsOf: b[j...]) }
        return out
    }

    // MARK: - Block-per-key storage

    /// The packed-block invariant means a term's blocks are `0...(df-1)/128`.
    @inline(__always)
    static func blockNo(forDF df: UInt64) -> UInt32 {
        UInt32((df - 1) / UInt64(FTSPostings.blockSize))
    }

    /// Postings key: `varint(termLen) || term || bigEndian(blockNo)`. The length
    /// prefix keeps one term's keys from colliding with another's (no term is a
    /// key-prefix of another), and the 4-byte big-endian `blockNo` sorts blocks
    /// ascending == docid-ascending.
    static func blockKey(_ term: [UInt8], _ no: UInt32) -> [UInt8] {
        var key = blockKeyPrefix(term)
        key.append(UInt8(truncatingIfNeeded: no >> 24))
        key.append(UInt8(truncatingIfNeeded: no >> 16))
        key.append(UInt8(truncatingIfNeeded: no >> 8))
        key.append(UInt8(truncatingIfNeeded: no))
        return key
    }

    /// The shared key prefix of a term's block-keys: `varint(len) || term`. A block
    /// adds a 4-byte big-endian `blockNo`; the length prefix means no term's prefix
    /// is a prefix of another's, so a range scan over this enumerates exactly one
    /// term's blocks.
    static func blockKeyPrefix(_ term: [UInt8]) -> [UInt8] {
        var key: [UInt8] = []
        key.reserveCapacity(term.count + 2)
        Varint.append(UInt64(term.count), to: &key)
        key.append(contentsOf: term)
        return key
    }

    /// Visits a term's block values in `blockNo` order via ONE cursor range scan
    /// (seek the prefix, walk while it holds) — far cheaper than a point-get per
    /// block on a multi-block term (one tree descent + leaf walk vs one descent
    /// each). Used by every read path.
    ///
    /// `body` receives each block value as a mapped-page span valid ONLY for that
    /// call (zero-copy: an inline value is the page bytes directly). Every caller
    /// decodes/copies what it needs within the call (`postingsValue` copies the
    /// body out, `docids`/`fullList` decode into their own arrays) and retains
    /// nothing — the span never escapes the resolver-snapshot scope.
    static func forEachBlockValue(
        _ resolver: some PageResolver, _ handle: TreeHandle, term: [UInt8],
        _ body: (UnsafeRawBufferPointer) throws(DBError) -> Void
    ) throws(DBError) {
        let prefix = blockKeyPrefix(term)
        var cursor = Cursor(resolver: resolver, tree: handle)
        var positioned = try prefix.withUnsafeBytesThrowing { raw throws(DBError) in
            _ = unsafe try cursor.seek(raw)
            return cursor.isValid
        }
        while positioned {
            // One cursor access per block: prefix-check the raw key in place (no key
            // copy) and hand the value's bytes to `body` zero-copy when it still
            // belongs to this term. `proceed` reports whether the block was in range;
            // false ⇒ key left the term's range (or the cursor went invalid) ⇒ stop.
            let proceed: Bool =
                unsafe try cursor.withCurrent { (key, ref) throws(DBError) -> Bool in
                    guard unsafe rawHasPrefix(key, prefix) else { return false }
                    unsafe try BTree.withValueBytes(ref, resolver: resolver) {
                        (raw) throws(DBError) in
                        unsafe try body(raw)
                    }
                    return true
                } ?? false
            guard proceed else { break }
            positioned = try cursor.next()
        }
    }

    /// Whether the raw cursor key begins with `prefix`, compared in place against the
    /// mapped page bytes (no `[UInt8]` materialization — the per-block key copy was
    /// pure overhead, the key is only tested, never kept).
    @inline(__always)
    static func rawHasPrefix(_ key: UnsafeRawBufferPointer, _ prefix: [UInt8]) -> Bool {
        guard key.count >= prefix.count else { return false }
        for index in 0 ..< prefix.count where unsafe key[index] != prefix[index] { return false }
        return true
    }

    /// The encode/decode layout shared by a term's posting blocks: the FTS column
    /// count and whether per-column positions are stored (detail != none).
    struct BlockLayout {
        let columns: Int
        let positions: Bool
    }

    static func writeBlock(
        _ ctx: TxnContext, _ handle: inout TreeHandle, term: [UInt8], blockNo no: UInt32,
        _ block: [FTSPosting], layout: BlockLayout
    ) throws(DBError) {
        try Relation.putBytes(
            ctx, &handle, key: blockKey(term, no),
            value: FTSPostings.encode(block, columns: layout.columns, storePositions: layout.positions))
    }

    static func readBlock(
        _ resolver: some PageResolver, _ handle: TreeHandle, term: [UInt8], blockNo no: UInt32,
        columns: Int, positions: Bool
    ) throws(DBError) -> [FTSPosting] {
        guard let value = try Relation.getBytes(resolver, handle, key: blockKey(term, no)) else {
            return []
        }
        return try FTSPostings.decode(value, columns: columns, storePositions: positions)
    }

    /// Decodes a term's whole list via a range scan over its block-keys.
    static func fullList(
        _ resolver: some PageResolver, _ handle: TreeHandle, term: [UInt8],
        columns: Int, positions: Bool
    ) throws(DBError) -> [FTSPosting] {
        var list: [FTSPosting] = []
        try forEachBlockValue(resolver, handle, term: term) { (value) throws(DBError) in
            // `decode` consumes a `[UInt8]`; rebuild it from the span (same cost as the
            // prior per-block `copyValue`, never worse) and consume it here.
            list.append(
                contentsOf: try FTSPostings.decode(
                    unsafe Array(value), columns: columns, storePositions: positions))
        }
        return list
    }

    /// Writes `list` (docid-ascending) as packed blocks `0...`.
    static func writePacked(
        _ ctx: TxnContext, _ handle: inout TreeHandle, term: [UInt8], _ list: [FTSPosting],
        columns: Int, positions: Bool
    ) throws(DBError) {
        var no: UInt32 = 0
        var start = 0
        while start < list.count {
            let end = min(start + FTSPostings.blockSize, list.count)
            try writeBlock(
                ctx, &handle, term: term, blockNo: no, Array(list[start ..< end]),
                layout: BlockLayout(columns: columns, positions: positions))
            no += 1
            start = end
        }
    }

    /// Re-packs a term after an out-of-order insert: drops the old `0...oldLastNo`
    /// blocks, then writes the merged list packed. (`list` is non-empty here.)
    static func rewritePacked(
        _ ctx: TxnContext, _ handle: inout TreeHandle, term: [UInt8], oldLastNo: UInt32,
        _ list: [FTSPosting], layout: BlockLayout
    ) throws(DBError) {
        let newLastNo = blockNo(forDF: UInt64(list.count))
        for no in 0 ... max(oldLastNo, newLastNo) {
            _ = try Relation.deleteBytes(ctx, &handle, key: blockKey(term, no))
        }
        try writePacked(ctx, &handle, term: term, list, columns: layout.columns, positions: layout.positions)
    }

    // MARK: - Helpers

    static func documentFrequency(
        _ resolver: some PageResolver, _ dict: TreeHandle, term: [UInt8]
    ) throws(DBError) -> UInt64 {
        guard let bytes = try Relation.getBytes(resolver, dict, key: term) else { return 0 }
        return decodeDF(bytes)
    }

    static func readGlobal(
        _ resolver: some PageResolver, _ handle: TreeHandle, columns: Int
    ) throws(DBError) -> FTSGlobalStats {
        var global: FTSGlobalStats
        if let bytes = try Relation.getBytes(resolver, handle, key: globalKey) {
            global = try FTSGlobalStats.decode(bytes)
        } else {
            global = FTSGlobalStats(docCount: 0, totalFieldLengths: [])
        }
        if global.totalFieldLengths.count < columns {
            global.totalFieldLengths += Array(
                repeating: 0, count: columns - global.totalFieldLengths.count)
        }
        return global
    }

    static func encodeDF(_ df: UInt64) -> [UInt8] {
        // A single varint, built into one exclusively-owned OutputSpan (no reserve foot-gun, no CoW).
        [UInt8](capacity: Varint.maxEncodedLength) { out in Varint.append(df, to: &out) }
    }

    static func decodeDF(_ bytes: [UInt8]) -> UInt64 {
        var offset = 0
        return Varint.read(bytes, &offset) ?? 0
    }

    /// Forward record: `varint fieldCount || field lengths || varint termCount ||
    /// (varint len || term bytes)*`.
    static func encodeForward(fieldLengths: [UInt32], terms: [[UInt8]]) -> [UInt8] {
        // Reserve once up front so the per-term appends never reallocate. Each term is ≤
        // `maxTermBytes` (256), so its length varint is ≤ 2 bytes; the two count headers and the
        // per-column field lengths are each bounded by `Varint.maxEncodedLength`.
        let termBytes = terms.reduce(0) { $0 + $1.count }
        var out: [UInt8] = []
        out.reserveCapacity(
            Varint.maxEncodedLength * (2 + fieldLengths.count) + terms.count * 2 + termBytes)
        Varint.append(UInt64(fieldLengths.count), to: &out)
        for length in fieldLengths { Varint.append(UInt64(length), to: &out) }
        Varint.append(UInt64(terms.count), to: &out)
        for term in terms {
            Varint.append(UInt64(term.count), to: &out)
            out.append(contentsOf: term)
        }
        return out
    }

    static func decodeForward(
        _ bytes: [UInt8]
    ) throws(DBError) -> (fieldLengths: [UInt32], terms: [[UInt8]]) {
        var offset = 0
        guard let fieldCount = Varint.read(bytes, &offset) else {
            throw DBError.integrityFailure("fts forward: missing field count")
        }
        var fieldLengths: [UInt32] = []
        for _ in 0 ..< Int(fieldCount) {
            guard let length = Varint.read(bytes, &offset) else {
                throw DBError.integrityFailure("fts forward: truncated field length")
            }
            fieldLengths.append(UInt32(truncatingIfNeeded: length))
        }
        guard let termCount = Varint.read(bytes, &offset) else {
            throw DBError.integrityFailure("fts forward: missing term count")
        }
        var terms: [[UInt8]] = []
        for _ in 0 ..< Int(termCount) {
            guard let length = Varint.read(bytes, &offset), offset + Int(length) <= bytes.count else {
                throw DBError.integrityFailure("fts forward: truncated term")
            }
            terms.append(Array(bytes[offset ..< offset + Int(length)]))
            offset += Int(length)
        }
        return (fieldLengths, terms)
    }
}
