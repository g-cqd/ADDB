/// Abstraction over the file the engine writes through. Production uses
/// `FileChannel`; crash-injection tests substitute a journaling channel that
/// can materialize torn power-cut images.
///
/// Reads in normal operation go through the shared mmap, not this protocol;
/// `pread` exists for the `.pread` read path (escape hatch + differential
/// oracle) and for tooling.
public protocol StorageChannel: AnyObject, Sendable {
    /// File descriptor of the real on-disk file (used for mmap).
    var fileDescriptor: Int32 { get }

    func fileSize() throws(DBError) -> Int
    func pread(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) throws(DBError)
    func pwrite(_ buffer: UnsafeRawBufferPointer, at offset: Int) throws(DBError)
    /// Writes `buffers` contiguously starting at `offset` (gather write).
    func pwritev(_ buffers: [UnsafeRawBufferPointer], at offset: Int) throws(DBError)
    func sync(_ profile: DurabilityProfile) throws(DBError)
    /// Ensures the file is at least `minimumSize` bytes long, preallocating
    /// contiguous space where the filesystem permits.
    func preallocate(minimumSize: Int) throws(DBError)
    func truncate(to size: Int) throws(DBError)
    func close()
}

extension StorageChannel {
    /// Byte-array convenience over `pwrite` (see `[UInt8].withUnsafeBytesThrowing`
    /// for why the typed-throws closure is routed through a capturing helper).
    public func pwrite(_ bytes: [UInt8], at offset: Int) throws(DBError) {
        try bytes.withUnsafeBytesThrowing { raw throws(DBError) in
            unsafe try pwrite(raw, at: offset)
        }
    }

    /// Byte-array convenience over `pread`.
    public func preadBytes(count: Int, at offset: Int) throws(DBError) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        try out.withUnsafeMutableBytesThrowing { raw throws(DBError) in
            unsafe try pread(into: raw, at: offset)
        }
        return out
    }
}
