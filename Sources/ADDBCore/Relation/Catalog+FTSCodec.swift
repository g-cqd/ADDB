import ADSQLModel

/// FTS virtual-table record codec (config + the three owned B+tree handles),
/// split from `Catalog.swift` to keep the enum body within the gate.
extension Catalog {
    // u8 recVersion || u32 LE ftsId || dict(18) || postings(18) || stats(18)
    // || u16 LE colCount || column names
    // || u8 tokenizeCount || tokenize tokens
    // || u8 contentKind (0 self, 1 external[+table+rowid], 2 contentless[+u8 del])
    // || u8 prefixCount || prefix sizes (u8 each)
    // || u8 detail (0 full, 1 column, 2 none) || u8 columnSize

    static func encode(_ record: FTSRecord) -> [UInt8] {
        var out: [UInt8] = [recordVersion]
        withUnsafeBytes(of: record.ftsId.littleEndian) { unsafe out.append(contentsOf: $0) }
        appendHandle(record.dict, to: &out)
        appendHandle(record.postings, to: &out)
        appendHandle(record.stats, to: &out)
        let definition = record.definition
        withUnsafeBytes(of: UInt16(definition.columns.count).littleEndian) {
            unsafe out.append(contentsOf: $0)
        }
        for column in definition.columns { appendName(column, to: &out) }
        out.append(UInt8(definition.tokenize.count))
        for token in definition.tokenize { appendName(token, to: &out) }
        switch definition.content {
            case .selfContained:
                out.append(0)
            case .external(let table, let rowid):
                out.append(1)
                appendName(table, to: &out)
                appendName(rowid, to: &out)
            case .contentless(let deleteEnabled):
                out.append(2)
                out.append(deleteEnabled ? 1 : 0)
        }
        out.append(UInt8(definition.prefix.count))
        for size in definition.prefix { out.append(UInt8(min(size, 255))) }
        switch definition.detail {
            case .full: out.append(0)
            case .column: out.append(1)
            case .none: out.append(2)
        }
        out.append(definition.columnSize ? 1 : 0)
        return out
    }

    static func decodeFTS(
        _ bytes: UnsafeRawBufferPointer, name: String
    ) throws(DBError) -> FTSRecord {
        var offset = 0
        guard bytes.count >= 1, unsafe bytes[0] == recordVersion else {
            throw DBError.integrityFailure("catalog: bad fts record version")
        }
        offset = 1
        guard offset + 4 <= bytes.count else {
            throw DBError.integrityFailure("catalog: truncated fts id")
        }
        let ftsId = unsafe UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        offset += 4
        let dict = unsafe try readHandle(bytes, &offset)
        let postings = unsafe try readHandle(bytes, &offset)
        let stats = unsafe try readHandle(bytes, &offset)
        guard offset + 2 <= bytes.count else {
            throw DBError.integrityFailure("catalog: truncated fts column count")
        }
        let columnCount = unsafe Int(
            UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
        offset += 2
        var columns: [String] = []
        columns.reserveCapacity(columnCount)
        for _ in 0 ..< columnCount { unsafe columns.append(try readName(bytes, &offset)) }

        guard offset < bytes.count else {
            throw DBError.integrityFailure("catalog: truncated fts tokenize count")
        }
        let tokenizeCount = unsafe Int(bytes[offset])
        offset += 1
        var tokenize: [String] = []
        for _ in 0 ..< tokenizeCount { unsafe tokenize.append(try readName(bytes, &offset)) }

        let content = unsafe try decodeFTSContent(bytes, &offset)

        guard offset < bytes.count else {
            throw DBError.integrityFailure("catalog: truncated fts prefix count")
        }
        let prefixCount = unsafe Int(bytes[offset])
        offset += 1
        var prefix: [Int] = []
        for _ in 0 ..< prefixCount {
            guard offset < bytes.count else {
                throw DBError.integrityFailure("catalog: truncated fts prefix")
            }
            unsafe prefix.append(Int(bytes[offset]))
            offset += 1
        }

        guard offset + 2 <= bytes.count else {
            throw DBError.integrityFailure("catalog: truncated fts detail/columnsize")
        }
        let detailRaw = unsafe bytes[offset]
        offset += 1
        let detail: FTSDetail
        switch detailRaw {
            case 0: detail = .full
            case 1: detail = .column
            case 2: detail = .none
            default: throw DBError.integrityFailure("catalog: unknown fts detail")
        }
        let columnSize = unsafe bytes[offset] != 0

        return FTSRecord(
            ftsId: ftsId, dict: dict, postings: postings, stats: stats,
            definition: FTSDefinition(
                name: name, columns: columns, tokenize: tokenize, content: content,
                prefix: prefix, detail: detail, columnSize: columnSize))
    }

    /// Decodes the FTS content mode (0 self-contained, 1 external[+table,+rowid],
    /// 2 contentless[+delete flag]); advances `offset` past the inline payload.
    private static func decodeFTSContent(
        _ bytes: UnsafeRawBufferPointer, _ offset: inout Int
    ) throws(DBError) -> FTSContentMode {
        guard offset < bytes.count else {
            throw DBError.integrityFailure("catalog: truncated fts content kind")
        }
        let contentKind = unsafe bytes[offset]
        offset += 1
        switch contentKind {
            case 0:
                return .selfContained
            case 1:
                let table = unsafe try readName(bytes, &offset)
                let rowid = unsafe try readName(bytes, &offset)
                return .external(table: table, rowid: rowid)
            case 2:
                guard offset < bytes.count else {
                    throw DBError.integrityFailure("catalog: truncated fts contentless flag")
                }
                let deleteEnabled = unsafe bytes[offset] != 0
                offset += 1
                return .contentless(deleteEnabled: deleteEnabled)
            default:
                throw DBError.integrityFailure("catalog: unknown fts content kind")
        }
    }
}
