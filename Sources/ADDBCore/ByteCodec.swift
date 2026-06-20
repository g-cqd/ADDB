import ADSQLModel

/// `withUnsafeBytes` variants that thread the engine's typed `DBError` through the closure — the one
/// DB-specific byte shim. LEB128 varints, little/big-endian loads/stores, and xxHash64 now live in
/// ``ADFCore`` (the single implementation shared with ADJSON); callers `import ADFCore` directly.
extension [UInt8] {
    /// `withUnsafeBytes` that lets `body` throw a typed `DBError`. The standard
    /// `withUnsafeBytes` is `rethrows`, but converting a `throws(DBError)` closure
    /// over `UnsafeRawBufferPointer` to `rethrows` crashes the Swift 6.4 frontend
    /// (SILGenCleanup: "Illegal convention for non-address types"), so the error is
    /// captured inside the non-throwing closure and rethrown after. Nest two calls
    /// for the common key+value case. Single source of truth for that workaround.
    @inline(__always)
    func withUnsafeBytesThrowing<R>(
        _ body: (UnsafeRawBufferPointer) throws(DBError) -> R
    ) throws(DBError) -> R {
        var failure: DBError?
        let result = withUnsafeBytes { (raw) -> R? in
            do throws(DBError) { return unsafe try body(raw) } catch {
                failure = error
                return nil
            }
        }
        if let failure { throw failure }
        return result!  // non-nil whenever `failure` is nil (body returned normally)
    }

    /// Mutable counterpart of `withUnsafeBytesThrowing`, same rationale.
    @inline(__always)
    mutating func withUnsafeMutableBytesThrowing<R>(
        _ body: (UnsafeMutableRawBufferPointer) throws(DBError) -> R
    ) throws(DBError) -> R {
        var failure: DBError?
        let result = withUnsafeMutableBytes { (raw) -> R? in
            do throws(DBError) { return unsafe try body(raw) } catch {
                failure = error
                return nil
            }
        }
        if let failure { throw failure }
        return result!
    }
}
