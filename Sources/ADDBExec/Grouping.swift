@_spi(ADDBEngine) import ADDBCore
import ADSQL
import ADSQLModel

/// A hashable, collation-aware grouping key for GROUP BY, DISTINCT, and
/// compound (UNION) deduplication. Canonicalization matches SQLite's grouping
/// equality: numeric classes unify (1 and 1.0 group together via an integral
/// REAL folding to INTEGER), NULLs are equal to each other, and text under a
/// NOCASE collation is ASCII-folded. `Value` itself stays non-Hashable.
struct GroupKey: Hashable {
    let parts: [Part]

    enum Part: Hashable {
        case null
        case integer(Int64)
        case real(Double)  // only non-integral reals reach here
        /// Text held by its original `String`; the canonical (raw, or NOCASE
        /// ASCII-folded) byte stream is hashed and compared *lazily* over its `utf8`
        /// view, never materialized into a fresh `[UInt8]`. `nocase` records whether
        /// the A–Z→a–z fold applies, exactly as `KeyCodec.asciiFolded` did.
        case text(String, nocase: Bool)
        case blob([UInt8])

        // Manual conformances for `.text`: the hashed bits and the `==` comparison
        // operate on the canonicalized UTF-8 byte sequence (with optional inline ASCII
        // folding) so they are bit-for-bit identical to hashing/comparing the former
        // pre-folded `[UInt8]` — DISTINCT/GROUP BY/UNION keys are unchanged. The other
        // cases keep the synthesized element-wise behavior.

        static func == (lhs: Part, rhs: Part) -> Bool {
            switch (lhs, rhs) {
                case (.null, .null):
                    return true
                case (.integer(let a), .integer(let b)):
                    return a == b
                case (.real(let a), .real(let b)):
                    return a == b
                case (.text(let a, let af), .text(let b, let bf)):
                    return textBytesEqual(a, foldA: af, b, foldB: bf)
                case (.blob(let a), .blob(let b)):
                    return a == b
                default:
                    return false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
                case .null:
                    hasher.combine(0 as UInt8)
                case .integer(let i):
                    hasher.combine(1 as UInt8)
                    hasher.combine(i)
                case .real(let d):
                    hasher.combine(2 as UInt8)
                    hasher.combine(d)
                case .text(let s, let nocase):
                    hasher.combine(3 as UInt8)
                    // Hash the canonical bytes one element at a time — identical to
                    // `Array(foldedBytes).hash(into:)` (Array hashes its count then each
                    // element), without allocating the array.
                    var count = 0
                    for byte in s.utf8 {
                        hasher.combine(Self.foldByte(byte, nocase))
                        count += 1
                    }
                    hasher.combine(count)
                case .blob(let b):
                    hasher.combine(4 as UInt8)
                    hasher.combine(b)
            }
        }

        /// SQLite NOCASE: ASCII A–Z → a–z only. Identical transform to
        /// `KeyCodec.asciiFolded`, applied per byte.
        @inline(__always)
        private static func foldByte(_ byte: UInt8, _ nocase: Bool) -> UInt8 {
            (nocase && byte >= 0x41 && byte <= 0x5A) ? byte | 0x20 : byte
        }

        /// Byte-for-byte equality of two strings' canonical (optionally folded) UTF-8,
        /// compared lazily over the `utf8` views with no array materialization.
        private static func textBytesEqual(
            _ a: String, foldA: Bool, _ b: String, foldB: Bool
        ) -> Bool {
            var ia = a.utf8.makeIterator()
            var ib = b.utf8.makeIterator()
            while true {
                let na = ia.next()
                let nb = ib.next()
                switch (na, nb) {
                    case (nil, nil):
                        return true
                    case (let x?, let y?):
                        if foldByte(x, foldA) != foldByte(y, foldB) { return false }
                    default:
                        return false
                }
            }
        }
    }

    init(_ values: [Value], collations: [Collation]) {
        self.parts = values.enumerated()
            .map { index, value in
                Self.canonicalize(value, collation: collations[index])
            }
    }

    static func canonicalize(_ value: Value, collation: Collation) -> Part {
        switch value {
            case .null:
                return .null
            case .integer(let i):
                return .integer(i)
            case .real(let d):
                // Group 1.0 with 1: fold an integral real that fits Int64 to INTEGER.
                if d.rounded() == d && d >= -9.223372036854776e18 && d < 9.223372036854776e18 {
                    return .integer(Int64(d))
                }
                return .real(d)
            case .text(let s):
                // Keep the original String; the canonical (NOCASE-folded or raw) byte
                // stream is produced lazily on hash/equality — no per-key `[UInt8]` copy.
                return .text(s, nocase: collation == .nocase)
            case .blob(let b):
                return .blob(b)
        }
    }
}
