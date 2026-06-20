import ADFUnicode

public import ADSQLModel

/// The `unicode61` tokenizer: split on non-token characters, case-fold, and
/// optionally remove diacritics — the SQLite FTS5 default tokenizer and the base
/// under `porter`. A "token character" is a Unicode letter or number; runs of
/// them are terms, everything else is a separator.
///
/// Hot loop is ASCII-only (a 128-way classify + `| 0x20` fold); non-ASCII routes
/// through the shared `ADFUnicode` kernel — `CaseFolding.lowercase` then (when
/// `remove_diacritics > 0`) `NFD` canonical decomposition with combining marks
/// dropped. This generalizes diacritic removal to every decomposable scalar
/// (replacing the old curated Latin table), so `remove_diacritics` 1 and 2 are
/// now equivalent — full NFD stripping, matching SQLite's `remove_diacritics=2`.
public struct Unicode61Tokenizer: FTSTokenizer {
    /// 0 = keep diacritics, 1/2 = remove (combining marks + curated Latin map).
    public let removeDiacritics: Int

    public init(removeDiacritics: Int = 1) {
        self.removeDiacritics = removeDiacritics
    }

    public init(arguments: [String]) throws(DBError) {
        var removeDiacritics = 1
        var index = 0
        while index < arguments.count {
            let key = arguments[index].lowercased()
            guard index + 1 < arguments.count else {
                throw DBError.sqlUnsupported("unicode61 option '\(key)' needs a value")
            }
            let value = arguments[index + 1]
            index += 2
            switch key {
                case "remove_diacritics":
                    guard let level = Int(value), (0 ... 2).contains(level) else {
                        throw DBError.sqlUnsupported("unicode61 remove_diacritics '\(value)'")
                    }
                    removeDiacritics = level
                default:
                    // tokenchars / separators / categories not needed by the consumer yet.
                    throw DBError.sqlUnsupported("unicode61 option '\(key)'")
            }
        }
        self.removeDiacritics = removeDiacritics
    }

    public func tokenize(
        _ text: [UInt8], _ sink: (FTSToken) throws(DBError) -> Void
    ) throws(DBError) {
        var term: [UInt8] = []
        var start = 0
        var position = 0
        var offset = 0

        // TEXT is always valid UTF-8 (stored from Swift `String.utf8`), so decoding
        // round-trips and `offset` stays aligned to the original byte buffer.
        for scalar in String(decoding: text, as: UTF8.self).unicodeScalars {
            let width = UTF8Text.width(scalar)
            if isTokenChar(scalar) {
                if term.isEmpty { start = offset }
                foldAppend(scalar, to: &term)
            } else if !term.isEmpty {
                try sink(FTSToken(term: term, start: start, end: offset, position: position))
                position += 1
                term.removeAll(keepingCapacity: true)
            }
            offset += width
        }
        if !term.isEmpty {
            try sink(FTSToken(term: term, start: start, end: offset, position: position))
        }
    }

    /// A token character is a Unicode letter or number. ASCII fast path avoids the
    /// Unicode-database lookup for the common case.
    func isTokenChar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x80 { return Self.asciiTokenFold(UInt8(scalar.value)) != nil }
        return Self.isTokenScalar(scalar)
    }

    // MARK: - Classification & folding

    /// For an ASCII byte: the folded token byte (lowercased letter / digit), or
    /// `nil` if it's a separator.
    static func asciiTokenFold(_ byte: UInt8) -> UInt8? {
        switch byte {
            case 0x41 ... 0x5A: return byte | 0x20  // A–Z → a–z
            case 0x61 ... 0x7A, 0x30 ... 0x39: return byte  // a–z, 0–9
            default: return nil
        }
    }

    static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        return properties.isAlphabetic || properties.numericType != nil
    }

    func foldAppend(_ scalar: Unicode.Scalar, to term: inout [UInt8]) {
        if scalar.value < 0x80 {
            if let folded = Self.asciiTokenFold(UInt8(scalar.value)) { term.append(folded) }
            return
        }
        // Non-ASCII (cold path): case-fold, then — when removing diacritics — canonically decompose and
        // drop combining marks, all via the shared `ADFUnicode` kernel. This strips every decomposable
        // diacritic (not just a curated Latin table); the ASCII fast path above is untouched.
        var folded = CaseFolding.lowercase([scalar])
        if removeDiacritics > 0 {
            folded = NFD.decompose(folded).filter { $0.properties.canonicalCombiningClass.rawValue == 0 }
        }
        for unit in folded { UTF8Text.append(unit, to: &term) }
    }
}
