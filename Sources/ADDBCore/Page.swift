import ADFCore

/// Node page header codec and slotted-page primitives.
///
/// Header (32 bytes):
/// 0–7 XXH64 over bytes 8..<16384, seeded with the page number
/// 8 page type (branch / leaf / overflow / freelist)
/// 9 flags (reserved)
/// 10–11 cellCount — for overflow pages: dataLen
/// 12–13 cellAreaStart (cell content grows down from the page end)
/// 14–15 fragmentedBytes (dead bytes inside the cell area)
/// 16–23 branch: leftmostChild · overflow: nextOverflowPage · else 0
/// 24–31 reserved
///
/// After the header comes the slot array (u16 cell offsets, key-sorted,
/// growing up) and, from the end of the page growing down, the cells.
@_spi(ADDBEngine) public enum PageHeader {
    @_spi(ADDBEngine) public enum Offset {
        @_spi(ADDBEngine) public static let checksum = 0
        @_spi(ADDBEngine) public static let pageType = 8
        @_spi(ADDBEngine) public static let flags = 9
        @_spi(ADDBEngine) public static let cellCount = 10
        @_spi(ADDBEngine) public static let cellAreaStart = 12
        @_spi(ADDBEngine) public static let fragmentedBytes = 14
        @_spi(ADDBEngine) public static let link = 16
        @_spi(ADDBEngine) public static let reserved = 24
    }

    // MARK: Reads

    @inline(__always)
    @_spi(ADDBEngine) public static func pageType(_ page: UnsafeRawBufferPointer) -> PageType? {
        unsafe PageType(rawValue: page[Offset.pageType])
    }
    @inline(__always)
    @_spi(ADDBEngine) public static func cellCount(_ page: UnsafeRawBufferPointer) -> Int {
        unsafe Int(page.loadLE16(Offset.cellCount))
    }
    @inline(__always)
    @_spi(ADDBEngine) public static func cellAreaStart(_ page: UnsafeRawBufferPointer) -> Int {
        unsafe Int(page.loadLE16(Offset.cellAreaStart))
    }
    @inline(__always)
    @_spi(ADDBEngine) public static func fragmentedBytes(_ page: UnsafeRawBufferPointer) -> Int {
        unsafe Int(page.loadLE16(Offset.fragmentedBytes))
    }
    /// Branch: leftmost child. Overflow: next page in the chain (0 = end).
    @inline(__always)
    @_spi(ADDBEngine) public static func link(_ page: UnsafeRawBufferPointer) -> UInt64 {
        unsafe page.loadLE64(Offset.link)
    }
    /// Overflow pages reuse the cellCount field as their payload length.
    @inline(__always)
    @_spi(ADDBEngine) public static func overflowDataLen(_ page: UnsafeRawBufferPointer) -> Int {
        unsafe cellCount(page)
    }

    @inline(__always)
    @_spi(ADDBEngine) public static func slotOffset(_ page: UnsafeRawBufferPointer, _ index: Int) -> Int {
        unsafe Int(page.loadLE16(Format.nodeHeaderSize + index * Format.slotSize))
    }

    /// Free space between the end of the slot array and cellAreaStart.
    @inline(__always)
    @_spi(ADDBEngine) public static func freeSpace(_ page: UnsafeRawBufferPointer) -> Int {
        unsafe cellAreaStart(page) - (Format.nodeHeaderSize + cellCount(page) * Format.slotSize)
    }

    // MARK: Writes

    // The page mutators take the buffer as an `inout MutableRawSpan` (vended by
    // `PageBuf.withMutableBytes`): the borrow checker bounds the byte view to the call, and the
    // `storeLE*` are bounds-checked. Byte layout is unchanged — same offsets, same little-endian
    // encoding, identical to the former `UnsafeMutableRawBufferPointer` codec.
    @_spi(ADDBEngine) public static func initialize(_ page: inout MutableRawSpan, type: PageType) {
        precondition(page.byteCount == Format.pageSize)
        unsafe page.withUnsafeMutableBytes { buf in
            unsafe buf.initializeMemory(as: UInt8.self, repeating: 0)
            return
        }
        page.storeBytes(of: type.rawValue, toByteOffset: Offset.pageType, as: UInt8.self)
        page.storeLE16(UInt16(Format.pageSize), at: Offset.cellAreaStart)
    }

    @inline(__always)
    @_spi(ADDBEngine) public static func setCellCount(_ page: inout MutableRawSpan, _ value: Int) {
        page.storeLE16(UInt16(value), at: Offset.cellCount)
    }
    @inline(__always)
    @_spi(ADDBEngine) public static func setCellAreaStart(_ page: inout MutableRawSpan, _ value: Int) {
        page.storeLE16(UInt16(value), at: Offset.cellAreaStart)
    }
    @inline(__always)
    @_spi(ADDBEngine) public static func setFragmentedBytes(_ page: inout MutableRawSpan, _ value: Int) {
        page.storeLE16(UInt16(value), at: Offset.fragmentedBytes)
    }
    @inline(__always)
    @_spi(ADDBEngine) public static func setLink(_ page: inout MutableRawSpan, _ value: UInt64) {
        page.storeLE64(value, at: Offset.link)
    }
    @inline(__always)
    @_spi(ADDBEngine) public static func setSlotOffset(
        _ page: inout MutableRawSpan, _ index: Int, _ value: Int
    ) {
        page.storeLE16(UInt16(value), at: Format.nodeHeaderSize + index * Format.slotSize)
    }

    // MARK: Checksums

    /// Stamps the page checksum. Called exactly once per dirty page at commit.
    @_spi(ADDBEngine) public static func stampChecksum(_ page: inout MutableRawSpan, pageNo: UInt64) {
        let digest = unsafe page.withUnsafeBytes { (ro: UnsafeRawBufferPointer) in
            unsafe XXH64.hash(UnsafeRawBufferPointer(rebasing: ro[8...]), seed: pageNo)
        }
        page.storeLE64(digest, at: Offset.checksum)
    }

    @_spi(ADDBEngine) public static func verifyChecksum(_ page: UnsafeRawBufferPointer, pageNo: UInt64) -> Bool {
        let body = unsafe UnsafeRawBufferPointer(rebasing: page[8...])
        return unsafe page.loadLE64(Offset.checksum) == XXH64.hash(body, seed: pageNo)
    }
}
