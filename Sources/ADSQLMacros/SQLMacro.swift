import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `#SQL("SELECT …")` — lightweight compile-time validation of a SQL string
/// literal, expanding to the literal unchanged. It checks, purely syntactically,
/// that the literal is non-empty, has balanced parentheses and quotes, and starts
/// with a recognized SQL keyword. It deliberately does NOT parse the full
/// statement: the engine's parser is entangled with ADDBCore `Value`/`ColumnType`,
/// which the plugin cannot link, so this catches the common typos at build time
/// while the real parse still happens in `prepare`.
struct SQLMacro: ExpressionMacro {
    static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) -> ExprSyntax {
        guard let argument = node.arguments.first?.expression,
            let literal = argument.as(StringLiteralExprSyntax.self),
            literal.segments.count == 1,
            let value = literal.representedLiteralValue
        else {
            // An interpolated or non-literal argument can't be checked here; the
            // real parse in `prepare` still validates it at run time. Pass it through.
            context.diagnose(
                Diagnostic(node: Syntax(node), message: SQLMacroDiagnostic.requiresStringLiteral))
            return "\(raw: node.arguments.first?.expression.description ?? "\"\"")"
        }
        if let problem = validate(value) {
            context.diagnose(Diagnostic(node: Syntax(literal), message: problem))
        }
        // Pass the (validated) literal through unchanged.
        return "\(literal)"
    }

    /// The leading keywords ADSQL statements may start with (case-insensitive).
    private static let leadingKeywords: Set<String> = [
        "SELECT", "INSERT", "REPLACE", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER",
        "WITH", "PRAGMA", "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE",
        "EXPLAIN", "VACUUM", "ANALYZE", "REINDEX", "ATTACH", "DETACH"
    ]

    /// Returns a diagnostic for the first problem found, or nil if the literal
    /// passes the lightweight checks.
    static func validate(_ sql: String) -> SQLMacroDiagnostic? {
        let trimmed = sql.trimmingCharactersInWhitespace()
        guard !trimmed.isEmpty else { return .empty }

        // Leading keyword (the first whitespace-delimited token, uppercased).
        let firstToken = trimmed.prefix { !$0.isWhitespace && $0 != "(" }
        guard leadingKeywords.contains(firstToken.uppercased()) else {
            return .unrecognizedKeyword(String(firstToken))
        }

        // Balanced parens and quotes, scanning so paren counting ignores characters
        // inside a single- or double-quoted span (SQL doubles a quote to escape it,
        // which keeps the running parity correct without special-casing).
        var parens = 0
        var inSingle = false
        var inDouble = false
        for character in sql {
            switch character {
                case "'" where !inDouble: inSingle.toggle()
                case "\"" where !inSingle: inDouble.toggle()
                case "(" where !inSingle && !inDouble:
                    parens += 1
                case ")" where !inSingle && !inDouble:
                    parens -= 1
                    if parens < 0 { return .unbalancedParens }
                default: break
            }
        }
        if inSingle || inDouble { return .unbalancedQuotes }
        if parens != 0 { return .unbalancedParens }
        return nil
    }
}

enum SQLMacroDiagnostic: DiagnosticMessage {
    case empty
    case unbalancedParens
    case unbalancedQuotes
    case unrecognizedKeyword(String)
    case requiresStringLiteral

    var diagnosticID: MessageID {
        let id: String
        switch self {
            case .empty: id = "empty"
            case .unbalancedParens: id = "unbalancedParens"
            case .unbalancedQuotes: id = "unbalancedQuotes"
            case .unrecognizedKeyword: id = "unrecognizedKeyword"
            case .requiresStringLiteral: id = "requiresStringLiteral"
        }
        return MessageID(domain: "ADSQLMacros.SQL", id: id)
    }

    var severity: DiagnosticSeverity { .error }

    var message: String {
        switch self {
            case .empty:
                return "#SQL requires a non-empty SQL statement."
            case .unbalancedParens:
                return "#SQL statement has unbalanced parentheses."
            case .unbalancedQuotes:
                return "#SQL statement has an unterminated quoted string or identifier."
            case .unrecognizedKeyword(let token):
                return
                    "#SQL statement starts with '\(token)', which is not a recognized SQL keyword "
                    + "(SELECT, INSERT, UPDATE, DELETE, CREATE, …)."
            case .requiresStringLiteral:
                return
                    "#SQL expects a string literal so it can be validated at compile time; a non-literal "
                    + "argument is passed through and validated only at prepare time."
        }
    }
}

extension String {
    /// Trims leading/trailing whitespace and newlines (the macro plugin avoids
    /// Foundation, so this is a small stdlib-only helper).
    fileprivate func trimmingCharactersInWhitespace() -> Substring {
        var view = self[...]
        while let first = view.first, first.isWhitespace { view = view.dropFirst() }
        while let last = view.last, last.isWhitespace { view = view.dropLast() }
        return view
    }
}
