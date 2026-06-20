import SwiftDiagnostics
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import ADSQLMacros

@Suite("ADSQLMacros — #SQL compile-time validation")
struct SQLMacroTests {
    let macroSpecs: [String: MacroSpec] = ["SQL": MacroSpec(type: SQLMacro.self)]

    // MARK: - Valid statements pass through unchanged

    @Test func selectPassesThrough() {
        expandsTo(#"#SQL("SELECT id, name FROM users WHERE id = ?")"#, #""SELECT id, name FROM users WHERE id = ?""#)
    }

    @Test func variousLeadingKeywordsAreAccepted() {
        expandsTo(#"#SQL("INSERT INTO t(a) VALUES (1)")"#, #""INSERT INTO t(a) VALUES (1)""#)
        expandsTo(
            #"#SQL("  with cte as (select 1) select * from cte")"#, #""  with cte as (select 1) select * from cte""#)
        expandsTo(#"#SQL("CREATE TABLE t(a INTEGER)")"#, #""CREATE TABLE t(a INTEGER)""#)
    }

    @Test func quotedStringWithParensAndKeywordIsBalanced() {
        // Parens / a stray keyword INSIDE a quoted literal must not trip the scan.
        expandsTo(#"#SQL("SELECT '(' || name || ') drop' FROM t")"#, #""SELECT '(' || name || ') drop' FROM t""#)
    }

    // MARK: - Invalid statements diagnose (and still pass the literal through)

    @Test func emptyIsDiagnosed() {
        expandsTo(
            #"#SQL("")"#, #""""#,
            diagnostics: [DiagnosticSpec(message: "#SQL requires a non-empty SQL statement.", line: 1, column: 6)])
    }

    @Test func unrecognizedKeywordIsDiagnosed() {
        expandsTo(
            #"#SQL("FOO bar")"#, #""FOO bar""#,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "#SQL statement starts with 'FOO', which is not a recognized SQL keyword "
                        + "(SELECT, INSERT, UPDATE, DELETE, CREATE, …).",
                    line: 1, column: 6)
            ])
    }

    @Test func unbalancedParensIsDiagnosed() {
        expandsTo(
            #"#SQL("SELECT (1")"#, #""SELECT (1""#,
            diagnostics: [
                DiagnosticSpec(message: "#SQL statement has unbalanced parentheses.", line: 1, column: 6)
            ])
    }

    @Test func unterminatedQuoteIsDiagnosed() {
        expandsTo(
            #"#SQL("SELECT 'oops")"#, #""SELECT 'oops""#,
            diagnostics: [
                DiagnosticSpec(
                    message: "#SQL statement has an unterminated quoted string or identifier.",
                    line: 1, column: 6)
            ])
    }

    // MARK: - Helper

    private func expandsTo(
        _ source: String,
        _ expanded: String,
        diagnostics: [DiagnosticSpec] = [],
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) {
        assertMacroExpansion(
            source,
            expandedSource: expanded,
            diagnostics: diagnostics,
            macroSpecs: macroSpecs,
            failureHandler: { spec in
                Issue.record(
                    Comment(rawValue: spec.message),
                    sourceLocation: Testing.SourceLocation(
                        fileID: spec.location.fileID,
                        filePath: spec.location.filePath,
                        line: spec.location.line,
                        column: spec.location.column
                    )
                )
            }
        )
    }
}
