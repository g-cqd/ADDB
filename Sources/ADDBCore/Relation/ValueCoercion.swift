#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Storage-class coercions on ``Value`` — SQLite's `CAST` and text/number
/// affinity semantics. These live at the value layer so the relational importer
/// (``Value/coerced(to:)``) and the SQL evaluator share one implementation,
/// without the value type depending on the SQL engine.
extension Value {
    /// Loose→strict coercion to a column type, matching SQLite's `CAST` — the
    /// sanctioned coercion boundary named in this type's doc, used by the SQLite
    /// importer to land dynamically-typed source cells into strict columns. NULL
    /// passes through unchanged.
    public func coerced(to type: ColumnType) -> Value {
        Value.cast(self, to: type)
    }

    /// SQLite text rendering of a value (for ||, CAST AS TEXT, LIKE).
    @_spi(ADDBEngine) public static func textify(_ value: Value) -> String {
        switch value {
        case .null: return ""  // callers handle NULL before textify
        case .integer(let v): return String(v)
        case .real(let d): return realToText(d)
        case .text(let s): return s
        case .blob(let b): return String(decoding: b, as: UTF8.self)
        }
    }

    /// SQLite formats reals with %!.15g, upgrading precision until the text
    /// round-trips.
    @_spi(ADDBEngine) public static func realToText(_ d: Double) -> String {
        if d.isNaN { return "" }  // NaN is NULL upstream
        if d.isInfinite { return d > 0 ? "Inf" : "-Inf" }
        for precision in [15, 17, 20] {
            let text = format(d, precision: precision)
            if Double(text) == d {
                return ensureRealShape(text)
            }
        }
        return ensureRealShape(format(d, precision: 20))
    }

    private static func format(_ d: Double, precision: Int) -> String {
        var buffer = [CChar](repeating: 0, count: 48)
        let result = "%.\(precision)g".withCString { fmt in
            unsafe withVaList([d]) { args in
                buffer.withUnsafeMutableBufferPointer { out in
                    unsafe vsnprintf(out.baseAddress!, out.count, fmt, args)
                }
            }
        }
        // `vsnprintf` returns < 0 only on an encoding error, which cannot happen for a
        // finite `d` and a `%g` format (callers already handle NaN/Inf). Fall back to
        // the standard-library rendering rather than crash if it ever does.
        guard result > 0 else { return String(d) }
        let written = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: written, as: UTF8.self)
    }

    /// SQLite always renders reals with a decimal point or exponent.
    private static func ensureRealShape(_ text: String) -> String {
        if text.contains(".") || text.contains("e") || text.contains("E")
            || text.contains("Inf")
        {
            return text
        }
        return text + ".0"
    }

    /// SQLite numeric-prefix coercion of text: leading spaces, sign, digits,
    /// optional fraction/exponent; empty/invalid prefix → integer 0.
    @_spi(ADDBEngine) public static func numericPrefix(_ s: String) -> Value {
        let bytes = Array(s.utf8)
        var i = 0
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
        let start = i
        if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
        var sawDigit = false
        while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
            sawDigit = true
            i += 1
        }
        var isReal = false
        if i < bytes.count, bytes[i] == 0x2E {
            isReal = true
            i += 1
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                sawDigit = true
                i += 1
            }
        }
        if sawDigit, i < bytes.count, bytes[i] | 0x20 == 0x65 {
            var j = i + 1
            if j < bytes.count, bytes[j] == 0x2B || bytes[j] == 0x2D { j += 1 }
            if j < bytes.count, bytes[j] >= 0x30, bytes[j] <= 0x39 {
                isReal = true
                i = j
                while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
            }
        }
        guard sawDigit else { return .integer(0) }
        let text = String(decoding: bytes[start..<i], as: UTF8.self)
        if !isReal, let v = Int64(text) { return .integer(v) }
        return .real(Double(text) ?? 0)
    }

    /// Numeric coercion for arithmetic operands.
    @_spi(ADDBEngine) public static func toNumeric(_ value: Value) -> Value {
        switch value {
        case .integer, .real, .null: return value
        case .text(let s): return numericPrefix(s)
        case .blob: return .integer(0)
        }
    }

    @_spi(ADDBEngine) public static func cast(_ value: Value, to type: ColumnType) -> Value {
        if value.isNull { return .null }
        switch type {
        case .integer:
            switch toNumeric(value) {
            case .integer(let v): return .integer(v)
            case .real(let d):
                if d.isNaN { return .integer(0) }
                if d <= -9.223372036854776e18 { return .integer(.min) }
                if d >= 9.223372036854776e18 { return .integer(.max) }
                return .integer(Int64(d))  // truncates toward zero
            default: return .integer(0)
            }
        case .real:
            switch toNumeric(value) {
            case .integer(let v): return .real(Double(v))
            case .real(let d): return .real(d)
            default: return .real(0)
            }
        case .text:
            return .text(textify(value))
        case .blob:
            if case .blob = value { return value }
            return .blob(Array(textify(value).utf8))
        }
    }
}
