/// A single owned, page-aligned 16 KiB buffer. Dirty pages live in these
/// (keyed by page number in the write transaction's dirty table); ownership
/// is unique so the backing memory is freed exactly once.
@safe public final class PageBuf {
    // The naked mutable buffer is `private`: the page mutators (`Node.*`/`PageHeader.*`) reach the
    // bytes through the compiler-checked ``withMutableBytes(_:)`` scope below (a `MutableRawSpan`
    // whose lifetime the borrow checker bounds to the call), and external code only needs the
    // read-only view. So the writable pointer never leaves the instance — neither as a bare pointer
    // nor escaping the scope. SAFETY: the buffer outlives every borrowed view of it — PageBuf owns
    // it for its whole lifetime and frees it exactly once in `deinit`.
    private let raw: UnsafeMutableRawBufferPointer
    /// Which batch request last gained mutable access (group-commit nesting).
    var requestEpoch: UInt32 = 0

    public init(zeroed: Bool = true) {
        let ptr = UnsafeMutableRawPointer.allocate(
            byteCount: Format.pageSize, alignment: Format.pageSize)
        unsafe self.raw = unsafe UnsafeMutableRawBufferPointer(start: ptr, count: Format.pageSize)
        if zeroed {
            unsafe raw.initializeMemory(as: UInt8.self, repeating: 0)
        }
    }

    public convenience init(copying source: UnsafeRawBufferPointer) {
        precondition(source.count == Format.pageSize)
        self.init(zeroed: false)
        unsafe raw.copyMemory(from: source)
    }

    deinit {
        unsafe raw.deallocate()
    }

    @inline(__always)
    public var readOnly: UnsafeRawBufferPointer { unsafe UnsafeRawBufferPointer(raw) }

    /// Vends the page's bytes as a `MutableRawSpan` for the duration of `body`. The span is the
    /// in-module writer surface (the `Node.*` / `PageHeader.*` page mutators take `inout
    /// MutableRawSpan`); the borrow checker bounds its lifetime to the call, so a page view can
    /// neither escape nor outlive the buffer. SAFETY: the span covers exactly the owned 16 KiB
    /// allocation, which lives for the whole `PageBuf` lifetime (freed once in `deinit`).
    @inline(__always)
    func withMutableBytes<E: Error, R: ~Copyable>(
        _ body: (inout MutableRawSpan) throws(E) -> R
    ) throws(E) -> R {
        var span = unsafe MutableRawSpan(_unsafeBytes: raw)
        return try body(&span)
    }
}
