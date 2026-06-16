package import ADDBCore

/// The MATCH query language. Parses an FTS5-style query string into an
/// operator tree; boolean evaluation over postings and the SQL `MATCH`
/// surface build on it. Grammar (precedence high→low): column filter
/// `col:` / `{a b}:` > `NOT` > `AND` (incl. implicit AND between adjacent terms)
/// > `OR`. `AND`/`OR`/`NOT` are case-sensitive uppercase keywords (FTS5).
///
/// A `phrase`'s `text` is the raw query token(s) — the table's tokenizer is
/// applied at evaluation, so `Running` matches the stemmed `run`, and a quoted
/// `"a b"` becomes an ordered adjacency. `prefix` marks a trailing `*`.
package indirect enum FTSQuery: Equatable, Sendable {
    case phrase(text: String, prefix: Bool)
    case and(FTSQuery, FTSQuery)
    case or(FTSQuery, FTSQuery)
    case not(FTSQuery, FTSQuery)
    case column(columns: [String], FTSQuery)

    package static func parse(_ query: String) throws(DBError) -> FTSQuery {
        var parser = MatchParser(tokens: MatchLexer.tokenize(Array(query.utf8)))
        let expr = try parser.parseOr()
        guard parser.atEnd else {
            throw DBError.sqlSyntax(message: "unexpected trailing tokens in MATCH query", offset: 0)
        }
        return expr
    }
}

private enum MatchToken: Equatable {
    case word(String)
    case string(String)
    case and, or, not
    case lparen, rparen, lbrace, rbrace, colon, star
}

private enum MatchLexer {
    static func isSpecial(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0D,
            UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "{"), UInt8(ascii: "}"),
            UInt8(ascii: ":"), UInt8(ascii: "*"), UInt8(ascii: "\""):
            return true
        default:
            return false
        }
    }

    static func tokenize(_ bytes: [UInt8]) -> [MatchToken] {
        var tokens: [MatchToken] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case UInt8(ascii: "("):
                tokens.append(.lparen)
                index += 1
            case UInt8(ascii: ")"):
                tokens.append(.rparen)
                index += 1
            case UInt8(ascii: "{"):
                tokens.append(.lbrace)
                index += 1
            case UInt8(ascii: "}"):
                tokens.append(.rbrace)
                index += 1
            case UInt8(ascii: ":"):
                tokens.append(.colon)
                index += 1
            case UInt8(ascii: "*"):
                tokens.append(.star)
                index += 1
            case UInt8(ascii: "\""):
                index += 1
                let start = index
                while index < bytes.count, bytes[index] != UInt8(ascii: "\"") { index += 1 }
                tokens.append(.string(String(decoding: bytes[start..<index], as: UTF8.self)))
                if index < bytes.count { index += 1 }  // closing quote
            default:
                let start = index
                while index < bytes.count, !isSpecial(bytes[index]) { index += 1 }
                let word = String(decoding: bytes[start..<index], as: UTF8.self)
                switch word {
                case "AND": tokens.append(.and)
                case "OR": tokens.append(.or)
                case "NOT": tokens.append(.not)
                default: tokens.append(.word(word))
                }
            }
        }
        return tokens
    }
}

private struct MatchParser {
    let tokens: [MatchToken]
    var pos = 0
    /// Recursive-descent nesting depth (parens, `col:` chains). Bounds the parser's
    /// own call stack so `(((…)))` / `a:b:c:…` cannot overflow it during parsing.
    /// Kept small because each level spends several frames (parseOr→…→parsePrimary),
    /// mirroring the SQL parser's structural-nesting cap; far beyond any real search.
    var depth = 0
    static let maxRecursionDepth = 48
    /// Operator nodes built so far. Bounds the `indirect enum FTSQuery` tree the
    /// loops below assemble for long boolean runs (`a OR b OR …`, adjacency runs),
    /// so a search string cannot build a node graph deep enough to overflow the
    /// recursive evaluators — or the recursive ARC teardown — on a small stack. The
    /// loops add no parser recursion, so this can be larger than the depth cap.
    var nodeCount = 0
    static let maxNodes = 256

    var current: MatchToken? { pos < tokens.count ? tokens[pos] : nil }
    var atEnd: Bool { pos >= tokens.count }

    mutating func countNode() throws(DBError) {
        nodeCount += 1
        guard nodeCount <= Self.maxNodes else {
            throw DBError.sqlSyntax(message: "MATCH query is too large", offset: 0)
        }
    }

    mutating func parseOr() throws(DBError) -> FTSQuery {
        var lhs = try parseAnd()
        while case .or = current {
            pos += 1
            let rhs = try parseAnd()
            try countNode()
            lhs = .or(lhs, rhs)
        }
        return lhs
    }

    mutating func parseAnd() throws(DBError) -> FTSQuery {
        var lhs = try parseNot()
        while true {
            if case .and = current {
                pos += 1
                let rhs = try parseNot()
                try countNode()
                lhs = .and(lhs, rhs)
            } else if startsPrimary(current) {
                let rhs = try parseNot()  // implicit AND between adjacent terms
                try countNode()
                lhs = .and(lhs, rhs)
            } else {
                break
            }
        }
        return lhs
    }

    mutating func parseNot() throws(DBError) -> FTSQuery {
        var lhs = try parsePrimary()
        while case .not = current {
            pos += 1
            let rhs = try parsePrimary()
            try countNode()
            lhs = .not(lhs, rhs)
        }
        return lhs
    }

    mutating func parsePrimary() throws(DBError) -> FTSQuery {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxRecursionDepth else {
            throw DBError.sqlSyntax(message: "MATCH query is nested too deeply", offset: 0)
        }
        guard let token = current else {
            throw DBError.sqlSyntax(message: "unexpected end of MATCH query", offset: 0)
        }
        switch token {
        case .lparen:
            pos += 1
            let expr = try parseOr()
            guard case .rparen = current else {
                throw DBError.sqlSyntax(message: "expected ')' in MATCH query", offset: 0)
            }
            pos += 1
            return expr
        case .lbrace:
            pos += 1
            var columns: [String] = []
            while case .word(let name) = current {
                columns.append(name)
                pos += 1
            }
            guard case .rbrace = current else {
                throw DBError.sqlSyntax(message: "expected '}' in MATCH column filter", offset: 0)
            }
            pos += 1
            guard case .colon = current else {
                throw DBError.sqlSyntax(message: "expected ':' after MATCH column filter", offset: 0)
            }
            pos += 1
            let inner = try parsePrimary()
            try countNode()
            return .column(columns: columns, inner)
        case .string(let text):
            pos += 1
            return .phrase(text: text, prefix: consumeStar())
        case .word(let word):
            pos += 1
            if case .colon = current {
                pos += 1
                let inner = try parsePrimary()
                try countNode()
                return .column(columns: [word], inner)
            }
            return .phrase(text: word, prefix: consumeStar())
        default:
            throw DBError.sqlSyntax(message: "unexpected token in MATCH query", offset: 0)
        }
    }

    mutating func consumeStar() -> Bool {
        if case .star = current {
            pos += 1
            return true
        }
        return false
    }

    func startsPrimary(_ token: MatchToken?) -> Bool {
        switch token {
        case .word, .string, .lparen, .lbrace: return true
        default: return false
        }
    }
}
