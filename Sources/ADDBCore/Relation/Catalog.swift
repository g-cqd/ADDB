import ADFCore
public import ADSQLModel

/// Catalog persistence: system rows in the main tree under the reserved
/// 0x00 prefix.
///
/// 00 76 → version row: catalogVersion u64 LE ||
/// nextTableId u32 LE || nextIndexId u32 LE
/// 00 74 <tableName> → TableRecord
/// 00 69 <indexName> → IndexRecord
/// 00 71 <tableId u32 BE> → AUTOINCREMENT high-water u64 LE
/// 00 66 <ftsName> → FTSRecord
/// 00 67 <triggerName> → raw CREATE TRIGGER SQL text (UTF-8; re-parsed)
///
/// Tree roots move on every COW commit, so records embed their TreeHandle
/// and `Relation.serializeState` rewrites changed records at commit time.
@_spi(ADDBEngine) public enum Catalog {
    static let prefix: UInt8 = 0x00
    static let kindVersion: UInt8 = 0x76  // 'v'
    static let kindTable: UInt8 = 0x74  // 't'
    static let kindIndex: UInt8 = 0x69  // 'i'
    static let kindSequence: UInt8 = 0x71  // 'q'
    static let kindFTS: UInt8 = 0x66  // 'f' — FTS virtual-table record
    static let kindTrigger: UInt8 = 0x67  // 'g' — CREATE TRIGGER text

    // MARK: - Keys

    static let versionKey: [UInt8] = [prefix, kindVersion]

    static func tableKey(_ name: String) -> [UInt8] {
        [prefix, kindTable] + Array(name.utf8)
    }

    static func indexKey(_ name: String) -> [UInt8] {
        [prefix, kindIndex] + Array(name.utf8)
    }

    static func sequenceKey(_ tableId: UInt32) -> [UInt8] {
        var key: [UInt8] = [prefix, kindSequence]
        withUnsafeBytes(of: tableId.bigEndian) { unsafe key.append(contentsOf: $0) }
        return key
    }

    static func ftsKey(_ name: String) -> [UInt8] {
        [prefix, kindFTS] + Array(name.utf8)
    }

    static func triggerKey(_ name: String) -> [UInt8] {
        [prefix, kindTrigger] + Array(name.utf8)
    }

    /// (lower, upper) bounds for scanning all keys of one kind.
    static func kindBounds(_ kind: UInt8) -> (lower: [UInt8], upper: [UInt8]) {
        ([prefix, kind], [prefix, kind + 1])
    }

    // MARK: - Version row

    struct VersionRow: Equatable, Sendable {
        var catalogVersion: UInt64 = 0
        var nextTableId: UInt32 = 1
        var nextIndexId: UInt32 = 1
    }

    static func encode(_ version: VersionRow) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(16)
        withUnsafeBytes(of: version.catalogVersion.littleEndian) { unsafe out.append(contentsOf: $0) }
        withUnsafeBytes(of: version.nextTableId.littleEndian) { unsafe out.append(contentsOf: $0) }
        withUnsafeBytes(of: version.nextIndexId.littleEndian) { unsafe out.append(contentsOf: $0) }
        return out
    }

    static func decodeVersion(_ bytes: UnsafeRawBufferPointer) throws(DBError) -> VersionRow {
        guard bytes.count >= 16 else { throw DBError.integrityFailure("catalog version row too short") }
        return unsafe VersionRow(
            catalogVersion: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self)),
            nextTableId: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
            nextIndexId: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
    }

    // MARK: - Records

    @_spi(ADDBEngine) public struct TableRecord: Equatable, Sendable {
        @_spi(ADDBEngine) public var tableId: UInt32
        @_spi(ADDBEngine) public var handle: TreeHandle
        @_spi(ADDBEngine) public var definition: TableDefinition

        @_spi(ADDBEngine) public init(tableId: UInt32, handle: TreeHandle, definition: TableDefinition) {
            self.tableId = tableId
            self.handle = handle
            self.definition = definition
        }
    }

    @_spi(ADDBEngine) public struct IndexRecord: Equatable, Sendable {
        @_spi(ADDBEngine) public var indexId: UInt32
        @_spi(ADDBEngine) public var tableId: UInt32
        @_spi(ADDBEngine) public var handle: TreeHandle
        @_spi(ADDBEngine) public var definition: IndexDefinition
    }

    /// An FTS virtual table: its config plus the three B+trees it owns (term
    /// dictionary, postings, doc/field stats). Roots are `.empty` until writes
    /// the first posting; `serializeState` rewrites the record when any moves.
    @_spi(ADDBEngine) public struct FTSRecord: Equatable, Sendable {
        @_spi(ADDBEngine) public var ftsId: UInt32
        @_spi(ADDBEngine) public var dict: TreeHandle
        @_spi(ADDBEngine) public var postings: TreeHandle
        @_spi(ADDBEngine) public var stats: TreeHandle
        @_spi(ADDBEngine) public var definition: FTSDefinition
    }

    static let recordVersion: UInt8 = 1

    static func appendName(_ name: String, to out: inout [UInt8]) {
        let utf8 = Array(name.utf8)
        precondition(utf8.count <= 255, "names are validated to ≤255 bytes")
        out.append(UInt8(utf8.count))
        out.append(contentsOf: utf8)
    }

    static func readName(
        _ bytes: UnsafeRawBufferPointer, _ offset: inout Int
    ) throws(DBError) -> String {
        guard offset < bytes.count else { throw DBError.integrityFailure("catalog: truncated name") }
        let length = unsafe Int(bytes[offset])
        offset += 1
        guard offset + length <= bytes.count else {
            throw DBError.integrityFailure("catalog: truncated name body")
        }
        let name = unsafe String(decoding: bytes[offset ..< offset + length], as: UTF8.self)
        offset += length
        return name
    }

    static func appendHandle(_ handle: TreeHandle, to out: inout [UInt8]) {
        withUnsafeBytes(of: handle.rootPage.littleEndian) { unsafe out.append(contentsOf: $0) }
        withUnsafeBytes(of: handle.depth.littleEndian) { unsafe out.append(contentsOf: $0) }
        withUnsafeBytes(of: handle.count.littleEndian) { unsafe out.append(contentsOf: $0) }
    }

    static func readHandle(
        _ bytes: UnsafeRawBufferPointer, _ offset: inout Int
    ) throws(DBError) -> TreeHandle {
        guard offset + 18 <= bytes.count else {
            throw DBError.integrityFailure("catalog: truncated tree handle")
        }
        let handle = unsafe TreeHandle(
            rootPage: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)),
            depth: UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt16.self)),
            count: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 10, as: UInt64.self)))
        offset += 18
        return handle
    }
}
