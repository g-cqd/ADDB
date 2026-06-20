import ADFCore
import ADSQLModel

/// TableRecord codec (table id, handle, columns/PK/FK definition), split from
/// `Catalog.swift` to keep the enum body within the gate.
extension Catalog {
    // TableRecord layout:
    // u8 recVersion || u32 LE tableId || handle(18) || u8 tableFlags
    // || u16 LE columnCount || columns || u8 pkKind (0 implicit, 1 alias)
    // || [alias: name + u8 autoincrement] || u8 fkCount || fks
    // Column: name || u8 type || u8 flags(bit0 notNull, bit1 nocase)
    // || u8 defaultKind (0 none,1 null,2 int,3 real,4 text,5 blob,6 now) || payload
    // FK: u8 colCount || names || parentName || u8 action

    static func encode(_ record: TableRecord) -> [UInt8] {
        var out: [UInt8] = [recordVersion]
        withUnsafeBytes(of: record.tableId.littleEndian) { unsafe out.append(contentsOf: $0) }
        appendHandle(record.handle, to: &out)
        out.append(0)  // tableFlags reserved
        let definition = record.definition
        withUnsafeBytes(of: UInt16(definition.columns.count).littleEndian) {
            unsafe out.append(contentsOf: $0)
        }
        for column in definition.columns {
            appendName(column.name, to: &out)
            out.append(column.type.rawValue)
            var flags: UInt8 = 0
            if column.notNull { flags |= 1 }
            if column.collation == .nocase { flags |= 2 }
            out.append(flags)
            switch column.defaultValue {
                case nil:
                    out.append(0)
                case .value(.null):
                    out.append(1)
                case .value(.integer(let v)):
                    out.append(2)
                    Varint.append(Varint.zigzag(v), to: &out)
                case .value(.real(let d)):
                    out.append(3)
                    withUnsafeBytes(of: d.bitPattern.littleEndian) { unsafe out.append(contentsOf: $0) }
                case .value(.text(let s)):
                    out.append(4)
                    let utf8 = Array(s.utf8)
                    withUnsafeBytes(of: UInt16(utf8.count).littleEndian) { unsafe out.append(contentsOf: $0) }
                    out.append(contentsOf: utf8)
                case .value(.blob(let b)):
                    out.append(5)
                    withUnsafeBytes(of: UInt16(b.count).littleEndian) { unsafe out.append(contentsOf: $0) }
                    out.append(contentsOf: b)
                case .datetimeNow:
                    out.append(6)
            }
        }
        switch definition.primaryKey {
            case .implicitRowid:
                out.append(0)
            case .rowidAlias(let column, let autoincrement):
                out.append(1)
                appendName(column, to: &out)
                out.append(autoincrement ? 1 : 0)
        }
        out.append(UInt8(definition.foreignKeys.count))
        for fk in definition.foreignKeys {
            out.append(UInt8(fk.childColumns.count))
            for column in fk.childColumns { appendName(column, to: &out) }
            appendName(fk.parentTable, to: &out)
            out.append(fk.onDelete.rawValue)
        }
        return out
    }

    static func decodeTable(
        _ bytes: UnsafeRawBufferPointer, name: String
    ) throws(DBError) -> TableRecord {
        var offset = 0
        guard bytes.count >= 1, unsafe bytes[0] == recordVersion else {
            throw DBError.integrityFailure("catalog: bad table record version")
        }
        offset = 1
        guard offset + 4 <= bytes.count else {
            throw DBError.integrityFailure("catalog: truncated table id")
        }
        let tableId = unsafe UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        offset += 4
        let handle = unsafe try readHandle(bytes, &offset)
        guard offset < bytes.count else { throw DBError.integrityFailure("catalog: truncated flags") }
        offset += 1  // tableFlags
        guard offset + 2 <= bytes.count else {
            throw DBError.integrityFailure("catalog: truncated column count")
        }
        let columnCount = unsafe Int(
            UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
        offset += 2

        let columns = unsafe try decodeColumns(bytes, &offset, count: columnCount)
        let primaryKey = unsafe try decodePrimaryKey(bytes, &offset)
        let foreignKeys = unsafe try decodeForeignKeys(bytes, &offset)

        return TableRecord(
            tableId: tableId, handle: handle,
            definition: TableDefinition(
                name, columns: columns, primaryKey: primaryKey, foreignKeys: foreignKeys))
    }

    /// Decodes `count` column definitions (name, type, flags, default) from `offset`.
    private static func decodeColumns(
        _ bytes: UnsafeRawBufferPointer, _ offset: inout Int, count: Int
    ) throws(DBError) -> [ColumnDefinition] {
        var columns: [ColumnDefinition] = []
        columns.reserveCapacity(count)
        for _ in 0 ..< count {
            let columnName = unsafe try readName(bytes, &offset)
            guard offset + 3 <= bytes.count else {
                throw DBError.integrityFailure("catalog: truncated column")
            }
            guard let type = unsafe ColumnType(rawValue: bytes[offset]) else {
                throw DBError.integrityFailure("catalog: unknown column type")
            }
            let flags = unsafe bytes[offset + 1]
            let defaultKind = unsafe bytes[offset + 2]
            offset += 3
            let defaultValue = unsafe try decodeColumnDefault(bytes, &offset, kind: defaultKind)
            columns.append(
                ColumnDefinition(
                    columnName, type, notNull: flags & 1 != 0,
                    collation: flags & 2 != 0 ? .nocase : .binary,
                    defaultValue: defaultValue))
        }
        return columns
    }

    /// Decodes one column's DEFAULT given its `kind` tag (0 none, 1 null, 2 int, 3 real,
    /// 4 text, 5 blob, 6 datetime-now); advances `offset` past any inline payload.
    private static func decodeColumnDefault(
        _ bytes: UnsafeRawBufferPointer, _ offset: inout Int, kind: UInt8
    ) throws(DBError) -> DefaultValue? {
        switch kind {
            case 0:
                return nil
            case 1:
                return .value(.null)
            case 2:
                guard let raw = unsafe Varint.read(bytes, &offset) else {
                    throw DBError.integrityFailure("catalog: truncated default int")
                }
                return .value(.integer(Varint.unzigzag(raw)))
            case 3:
                guard offset + 8 <= bytes.count else {
                    throw DBError.integrityFailure("catalog: truncated default real")
                }
                let bits = unsafe UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                offset += 8
                return .value(.real(Double(bitPattern: bits)))
            case 4, 5:
                guard offset + 2 <= bytes.count else {
                    throw DBError.integrityFailure("catalog: truncated default length")
                }
                let length = unsafe Int(
                    UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
                offset += 2
                guard offset + length <= bytes.count else {
                    throw DBError.integrityFailure("catalog: truncated default body")
                }
                let payload = unsafe bytes[offset ..< offset + length]
                offset += length
                return unsafe kind == 4
                    ? .value(.text(String(decoding: payload, as: UTF8.self)))
                    : .value(.blob([UInt8](payload)))
            case 6:
                return .datetimeNow
            default:
                throw DBError.integrityFailure("catalog: unknown default kind")
        }
    }

    /// Decodes the primary-key descriptor (implicit rowid, or a rowid-alias column
    /// with its autoincrement flag).
    private static func decodePrimaryKey(
        _ bytes: UnsafeRawBufferPointer, _ offset: inout Int
    ) throws(DBError) -> PrimaryKey {
        guard offset < bytes.count else { throw DBError.integrityFailure("catalog: truncated pk") }
        let pkKind = unsafe bytes[offset]
        offset += 1
        switch pkKind {
            case 0:
                return .implicitRowid
            case 1:
                let column = unsafe try readName(bytes, &offset)
                guard offset < bytes.count else {
                    throw DBError.integrityFailure("catalog: truncated autoincrement flag")
                }
                let autoincrement = unsafe bytes[offset] != 0
                offset += 1
                return .rowidAlias(column: column, autoincrement: autoincrement)
            default:
                throw DBError.integrityFailure("catalog: unknown pk kind")
        }
    }

    /// Decodes the foreign-key list (u8 count; each: u8 child-column count, child column
    /// names, parent table name, u8 ON DELETE action).
    private static func decodeForeignKeys(
        _ bytes: UnsafeRawBufferPointer, _ offset: inout Int
    ) throws(DBError) -> [ForeignKey] {
        guard offset < bytes.count else { throw DBError.integrityFailure("catalog: truncated fk count") }
        let fkCount = unsafe Int(bytes[offset])
        offset += 1
        var foreignKeys: [ForeignKey] = []
        for _ in 0 ..< fkCount {
            guard offset < bytes.count else {
                throw DBError.integrityFailure("catalog: truncated fk")
            }
            let colCount = unsafe Int(bytes[offset])
            offset += 1
            var childColumns: [String] = []
            for _ in 0 ..< colCount { unsafe childColumns.append(try readName(bytes, &offset)) }
            let parent = unsafe try readName(bytes, &offset)
            guard offset < bytes.count, let action = unsafe FKAction(rawValue: bytes[offset]) else {
                throw DBError.integrityFailure("catalog: bad fk action")
            }
            offset += 1
            foreignKeys.append(
                ForeignKey(childColumns: childColumns, parentTable: parent, onDelete: action))
        }
        return foreignKeys
    }
}
