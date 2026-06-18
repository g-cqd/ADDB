import ADFIO

/// Read-only shared mapping of the database file.
///
/// Thin engine-facing wrapper over ADFIO's ``RawFileMap``: it adds the B+tree
/// page indexing (`Format.pageSize`) on top of the neutral byte mapping. The
/// full maximum map size is reserved once at open — virtual address reservation
/// is free, macOS has no `mremap`, and the file simply grows underneath the
/// mapping (pages become valid as the file is extended, no remap needed).
/// Readers never touch pages past the committed `pageCount`, so they can never
/// fault past EOF in correct operation.
///
/// The database file is never truncated while mapped (free pages are recycled
/// instead; compaction is an offline copy), which is what makes handing out
/// borrowed views of mapped pages sound.
public final class MMap: @unchecked Sendable {
    private let map: RawFileMap
    public var capacity: Int { map.capacity }

    public init(fileDescriptor: Int32, capacity: Int) throws(DBError) {
        do { self.map = try RawFileMap(fileDescriptor: fileDescriptor, capacity: capacity) } catch {
            throw DBError.io(errno: error.errno, op: error.op)
        }
    }

    /// Borrowed view of one page. The caller must guarantee `pageNo` lies
    /// within the committed file (enforced by reading only via a transaction's
    /// meta snapshot). The `precondition` is an always-on (release included)
    /// backstop for this engine: it converts a corrupt/ungated `pageNo` whose
    /// byte offset would overflow or fall outside the mapping into a clean trap
    /// instead of a wild read — defense in depth behind the throwing gates in
    /// `Pager.page` / the transaction resolvers.
    @inline(__always)
    public func pageBytes(_ pageNo: UInt64) -> UnsafeRawBufferPointer {
        let pageSize = UInt64(Format.pageSize)
        let cap = UInt64(capacity)
        let (offset, overflow) = pageNo.multipliedReportingOverflow(by: pageSize)
        unsafe precondition(
            !overflow && offset <= cap && cap - offset >= pageSize,
            "ADDB: page \(pageNo) lies outside the mapped range (corrupt page reference)")
        return unsafe map.region(offset: Int(offset), count: Format.pageSize)
    }

    /// Advisory readahead for a contiguous run of `count` pages starting at
    /// `fromPage`. Out-of-range tails are clamped to the reserved capacity; the
    /// run beyond EOF is harmless (those pages are simply not resident yet and
    /// never get touched in correct use).
    @inline(__always)
    public func prefetch(fromPage: UInt64, count: Int) {
        map.prefetch(offset: Int(fromPage) * Format.pageSize, length: count * Format.pageSize)
    }

    @inline(__always)
    public func bytes(at offset: Int, count: Int) -> UnsafeRawBufferPointer {
        unsafe map.region(offset: offset, count: count)
    }
}
