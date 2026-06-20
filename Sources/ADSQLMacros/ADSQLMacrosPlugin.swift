import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ADSQLMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        SQLMacro.self,
        TableMacro.self
    ]
}
