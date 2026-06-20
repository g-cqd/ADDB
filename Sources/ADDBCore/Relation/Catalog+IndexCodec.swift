import ADSQLModel

/// IndexRecord codec (index id, table id, handle, definition + covering INCLUDE
/// columns), split from `Catalog.swift` to keep the enum body within the gate.
extension Catalog {
    // IndexRecord layout (self-contained: single-record fetches need no scan):
    // u8 recVersion || u32 LE indexId || u32 LE tableId || handle(18)
    // || u8 idxFlags(bit0 unique) || tableName || u8 colCount || column names
    // [optional, trailing] u8 includeCount || include column names
    // The trailing INCLUDE block is back-compatible: records written before
    // covering indexes have no trailing bytes and decode to `includes: []`, so no
    // recordVersion bump is needed and old databases keep opening.

    static func encode(_ record: IndexRecord) -> [UInt8] {
        var out: [UInt8] = [recordVersion]
        withUnsafeBytes(of: record.indexId.littleEndian) { unsafe out.append(contentsOf: $0) }
        withUnsafeBytes(of: record.tableId.littleEndian) { unsafe out.append(contentsOf: $0) }
        appendHandle(record.handle, to: &out)
        out.append(record.definition.unique ? 1 : 0)
        appendName(record.definition.table, to: &out)
        out.append(UInt8(record.definition.columns.count))
        for column in record.definition.columns { appendName(column, to: &out) }
        if !record.definition.includes.isEmpty {
            out.append(UInt8(record.definition.includes.count))
            for column in record.definition.includes { appendName(column, to: &out) }
        }
        return out
    }

    static func decodeIndex(
        _ bytes: UnsafeRawBufferPointer, name: String
    ) throws(DBError) -> IndexRecord {
        var offset = 0
        guard bytes.count >= 1, unsafe bytes[0] == recordVersion else {
            throw DBError.integrityFailure("catalog: bad index record version")
        }
        offset = 1
        guard offset + 8 <= bytes.count else {
            throw DBError.integrityFailure("catalog: truncated index ids")
        }
        let indexId = unsafe UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        let tableId = unsafe UInt32(
            littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
        offset += 8
        let handle = unsafe try readHandle(bytes, &offset)
        guard offset < bytes.count else {
            throw DBError.integrityFailure("catalog: truncated index flags")
        }
        let unique = unsafe bytes[offset] & 1 != 0
        offset += 1
        let table = unsafe try readName(bytes, &offset)
        guard offset < bytes.count else {
            throw DBError.integrityFailure("catalog: truncated index column count")
        }
        let colCount = unsafe Int(bytes[offset])
        offset += 1
        var columns: [String] = []
        for _ in 0 ..< colCount { unsafe columns.append(try readName(bytes, &offset)) }
        // Trailing INCLUDE block (absent in pre-covering records → empty).
        var includes: [String] = []
        if offset < bytes.count {
            let includeCount = unsafe Int(bytes[offset])
            offset += 1
            for _ in 0 ..< includeCount { unsafe includes.append(try readName(bytes, &offset)) }
        }
        return IndexRecord(
            indexId: indexId, tableId: tableId, handle: handle,
            definition: IndexDefinition(
                name, on: table, columns: columns, unique: unique, includes: includes))
    }
}
