/// Production page source: committed pages served zero-copy from the shared
/// mapping. Correctness of bounds comes from reading only page numbers
/// reachable from a committed meta (pages `[0, meta.pageCount)` always lie
/// within the file).
@_spi(ADDBEngine) public final class Pager: PageSource, @unchecked Sendable {
    @_spi(ADDBEngine) public let channel: any StorageChannel
    @_spi(ADDBEngine) public let map: MMap
    /// Forward-scan readahead window in pages (from `DatabaseOptions`; 0 disables).
    @_spi(ADDBEngine) public let prefetchWindow: Int

    @_spi(ADDBEngine) public init(
        channel: any StorageChannel, maxMapSize: Int, readaheadBytes: Int = 0
    ) throws(DBError) {
        self.channel = channel
        self.map = try MMap(fileDescriptor: channel.fileDescriptor, capacity: maxMapSize)
        self.prefetchWindow = max(0, readaheadBytes / Format.pageSize)
    }

    @inline(__always)
    @_spi(ADDBEngine) public func page(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer {
        let end = (Int(pageNo) + 1) * Format.pageSize
        guard end <= map.capacity else { throw DBError.mapFull }
        return unsafe map.pageBytes(pageNo)
    }

    @inline(__always)
    @_spi(ADDBEngine) public func prefetch(fromPage: UInt64, count: Int) {
        map.prefetch(fromPage: fromPage, count: count)
    }
}
