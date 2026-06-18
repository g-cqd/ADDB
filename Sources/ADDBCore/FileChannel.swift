public import ADFIO

/// POSIX-backed `StorageChannel`. Wraps ADFIO's ``PosixFile`` (the positioned
/// read/write, vectored write, durability, and space-management mechanics) and
/// maps its domain-neutral ``IOError`` into the engine's `DBError` taxonomy.
/// All calls are stateless per-fd operations, safe to issue from any thread.
@_spi(ADDBEngine) public final class FileChannel: StorageChannel, @unchecked Sendable {
    private let file: PosixFile
    @_spi(ADDBEngine) public var fileDescriptor: Int32 { file.fileDescriptor }

    @_spi(ADDBEngine) public typealias Mode = PosixFile.Mode

    @_spi(ADDBEngine) public init(path: String, mode: Mode) throws(DBError) {
        do { self.file = try PosixFile(path: path, mode: mode) } catch { throw error.asDBError }
    }

    /// Wraps an already-open descriptor (ownership not transferred).
    @_spi(ADDBEngine) public init(borrowing fd: Int32) {
        self.file = PosixFile(borrowing: fd)
    }

    @_spi(ADDBEngine) public func fileSize() throws(DBError) -> Int {
        do { return try file.fileSize() } catch { throw error.asDBError }
    }

    @_spi(ADDBEngine) public func pread(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) throws(DBError) {
        do { unsafe try file.pread(into: buffer, at: offset) } catch { throw error.asDBError }
    }

    @_spi(ADDBEngine) public func pwrite(_ buffer: UnsafeRawBufferPointer, at offset: Int) throws(DBError) {
        do { unsafe try file.pwrite(buffer, at: offset) } catch { throw error.asDBError }
    }

    @_spi(ADDBEngine) public func pwritev(_ buffers: [UnsafeRawBufferPointer], at offset: Int) throws(DBError) {
        do { unsafe try file.pwritev(buffers, at: offset) } catch { throw error.asDBError }
    }

    @_spi(ADDBEngine) public func sync(_ profile: DurabilityProfile) throws(DBError) {
        do { try file.sync(profile) } catch { throw error.asDBError }
    }

    @_spi(ADDBEngine) public func preallocate(minimumSize: Int) throws(DBError) {
        do { try file.preallocate(minimumSize: minimumSize) } catch { throw error.asDBError }
    }

    @_spi(ADDBEngine) public func truncate(to size: Int) throws(DBError) {
        do { try file.truncate(to: size) } catch { throw error.asDBError }
    }

    /// Toggles the unified-buffer-cache bypass for bulk load paths.
    @_spi(ADDBEngine) public func setNoCache(_ enabled: Bool) {
        file.setNoCache(enabled)
    }

    @_spi(ADDBEngine) public func close() {
        file.close()
    }
}

extension IOError {
    /// Lifts a neutral I/O failure into the engine error taxonomy, preserving the
    /// captured `errno` and operation label verbatim.
    fileprivate var asDBError: DBError { .io(errno: errno, op: op) }
}
