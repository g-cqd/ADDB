import SwiftDiagnostics
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import ADSQLMacros

/// Diagnostic-shape tests for `@Table`. The happy-path synthesis is covered
/// end-to-end (it compiles and round-trips) by `TableMacroIntegrationTests` in
/// ADDBTests, which is more robust than pinning the byte-exact expanded source.
struct TableMacroTests {
    let macroSpecs: [String: MacroSpec] = ["Table": MacroSpec(type: TableMacro.self)]

    @Test func unsupportedTypeIsDiagnosed() {
        expandsTo(
            """
            @Table
            struct Bad {
              let when: Date
            }
            """,
            """
            struct Bad {
              let when: Date
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Table does not support the type 'Date' of property 'when'. Supported column "
                        + "types are Int64, Int, Bool, String, Double, [UInt8], and a single optional layer.",
                    line: 3, column: 13)
            ])
    }

    @Test func enumIsRejected() {
        expandsTo(
            """
            @Table
            enum Status {
              case active
            }
            """,
            """
            enum Status {
              case active
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Table can only be applied to a struct.", line: 1, column: 1)
            ])
    }

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
