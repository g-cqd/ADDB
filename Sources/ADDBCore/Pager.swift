public import ADSQLModel

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
        // Bound `pageNo` in the UInt64 domain BEFORE any Int cast. A corrupt or
        // attacker-supplied page number near UInt64.max would otherwise trap in
        // `Int(pageNo)` or integer-overflow `(Int(pageNo)+1) * pageSize` to a
        // small/negative value that slips past a byte-offset bound. `pageNo <
        // capacity/pageSize` is exactly `(pageNo+1)*pageSize <= capacity` and
        // guarantees the subsequent offset math in `pageBytes` cannot overflow.
        let maxPages = UInt64(map.capacity / Format.pageSize)
        guard pageNo < maxPages else { throw DBError.mapFull }
        return unsafe map.pageBytes(pageNo)
    }

    @inline(__always)
    @_spi(ADDBEngine) public func prefetch(fromPage: UInt64, count: Int) {
        map.prefetch(fromPage: fromPage, count: count)
    }
}
