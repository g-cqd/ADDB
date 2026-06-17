import ADFMacroSupport
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Table` synthesizes `TableRow` conformance for a struct by reading its stored
/// properties: a `TableDefinition` whose columns mirror the properties (Swift type
/// → column affinity; an optional property → a nullable column) and an
/// `init(row:)` that decodes a `SQLRow` positionally. The generated source names
/// ADSQL/ADDBCore types unqualified (the consumer imports ADSQL), so the plugin
/// itself links neither.
struct TableMacro: ExtensionMacro {
    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(Diagnostic(node: Syntax(node), message: TableMacroDiagnostic.unsupportedDeclaration))
            return []
        }

        let tableName = explicitName(from: node) ?? type.trimmedDescription

        var columnDefs: [String] = []
        var decodeLines: [String] = []

        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            if isTypeLevelOrLazy(varDecl) { continue }
            let bindings = Array(varDecl.bindings)
            for index in bindings.indices {
                let binding = bindings[index]
                guard isStoredBinding(binding) else { continue }
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                let name = bareIdentifier(pattern.identifier.text)

                guard let resolved = resolvedType(at: index, in: bindings) else {
                    context.diagnose(
                        Diagnostic(node: Syntax(binding), message: TableMacroDiagnostic.requiresTypeAnnotation(name)))
                    return []
                }
                guard let column = classify(resolved) else {
                    context.diagnose(
                        Diagnostic(
                            node: Syntax(resolved),
                            message: TableMacroDiagnostic.unsupportedType(name, resolved.trimmedDescription)))
                    return []
                }
                let slot = decodeLines.count
                columnDefs.append(
                    "ColumnDefinition(\(swiftStringLiteral(name)), .\(column.affinity), notNull: \(column.notNull))")
                decodeLines.append(decodeLine(name: name, table: tableName, slot: slot, column: column))
            }
        }

        guard !columnDefs.isEmpty else {
            context.diagnose(Diagnostic(node: Syntax(node), message: TableMacroDiagnostic.noStoredProperties))
            return []
        }

        let columns = columnDefs.joined(separator: ",\n")
        let decode = decodeLines.joined(separator: "\n")
        let source: DeclSyntax = """
            extension \(type.trimmed): TableRow {
              public static var tableDefinition: TableDefinition {
                TableDefinition(
                  \(raw: swiftStringLiteral(tableName)),
                  columns: [
                    \(raw: columns)
                  ])
              }
              public init(row: SQLRow) throws(DBError) {
                \(raw: decode)
              }
            }
            """
        guard let ext = source.as(ExtensionDeclSyntax.self) else { return [] }
        return [ext]
    }

    // MARK: - Column classification

    private struct Column {
        /// The ADDBCore `ColumnType` case name (`integer`/`real`/`text`/`blob`).
        let affinity: String
        let notNull: Bool
        /// The `Value` case the decode expects (`integer`/`real`/`text`/`blob`).
        let valueCase: String
        /// Converts the bound payload to the property's Swift type (`{v}` substituted).
        let convert: (String) -> String
    }

    /// Maps a stored property's type to a column, or nil if unsupported (diagnosed).
    /// Supports Int64/Int/Bool/String/Double/[UInt8] and one optional layer.
    private static func classify(_ type: TypeSyntax) -> Column? {
        if let inner = optionalInner(type) {
            guard optionalInner(inner) == nil, let base = scalar(inner) else { return nil }
            return Column(affinity: base.affinity, notNull: false, valueCase: base.valueCase, convert: base.convert)
        }
        guard let base = scalar(type) else { return nil }
        return Column(affinity: base.affinity, notNull: true, valueCase: base.valueCase, convert: base.convert)
    }

    private struct Scalar {
        let affinity: String
        let valueCase: String
        let convert: (String) -> String
    }

    /// Classifies a non-optional scalar type into a column affinity + decode rule.
    private static func scalar(_ type: TypeSyntax) -> Scalar? {
        // `[UInt8]` → BLOB.
        if let array = type.as(ArrayTypeSyntax.self),
            let element = array.element.as(IdentifierTypeSyntax.self), element.name.text == "UInt8"
        {
            return Scalar(affinity: "blob", valueCase: "blob", convert: { $0 })
        }
        guard let identifier = type.as(IdentifierTypeSyntax.self) else { return nil }
        switch identifier.name.text {
        case "Int64": return Scalar(affinity: "integer", valueCase: "integer", convert: { $0 })
        case "Int": return Scalar(affinity: "integer", valueCase: "integer", convert: { "Int(\($0))" })
        case "Bool": return Scalar(affinity: "integer", valueCase: "integer", convert: { "\($0) != 0" })
        case "String": return Scalar(affinity: "text", valueCase: "text", convert: { $0 })
        case "Double": return Scalar(affinity: "real", valueCase: "real", convert: { $0 })
        default: return nil
        }
    }

    // MARK: - Decode-line generation

    /// One property's decode, emitted as single-line statements so the expansion
    /// formats with consistent indentation (a hand-indented multi-line block would
    /// render misaligned).
    private static func decodeLine(name: String, table: String, slot: Int, column: Column) -> String {
        let bound = "value\(slot)"
        let expected = column.valueCase.uppercased()
        let target = "self.\(escapedIdentifier(name))"
        if column.notNull {
            let message = swiftStringLiteral("\(table).\(name): expected \(expected)")
            return "guard case .\(column.valueCase)(let \(bound)) = row[\(slot)] else "
                + "{ throw DBError.sqlRuntime(\(message)) }\n\(target) = \(column.convert(bound))"
        }
        let nullMessage = swiftStringLiteral("\(table).\(name): expected \(expected) or NULL")
        return "if case .null = row[\(slot)] { \(target) = nil } "
            + "else if case .\(column.valueCase)(let \(bound)) = row[\(slot)] { \(target) = \(column.convert(bound)) } "
            + "else { throw DBError.sqlRuntime(\(nullMessage)) }"
    }

    // MARK: - Macro arguments

    /// The explicit table name from `@Table("…")`, if present and a string literal.
    private static func explicitName(from node: AttributeSyntax) -> String? {
        guard case .argumentList(let args) = node.arguments, let first = args.first,
            let literal = first.expression.as(StringLiteralExprSyntax.self),
            literal.segments.count == 1, let value = literal.representedLiteralValue
        else { return nil }
        return value
    }

    // MARK: - Binding inspection (mirrors the @URLQuery walker)

    private static func isTypeLevelOrLazy(_ varDecl: VariableDeclSyntax) -> Bool {
        varDecl.modifiers.contains { modifier in
            switch modifier.name.tokenKind {
            case .keyword(.static), .keyword(.class), .keyword(.lazy): return true
            default: return false
            }
        }
    }

    private static func isStoredBinding(_ binding: PatternBindingSyntax) -> Bool {
        guard let accessorBlock = binding.accessorBlock else { return true }
        switch accessorBlock.accessors {
        case .getter: return false
        case .accessors(let accessors):
            return accessors.allSatisfy { accessor in
                switch accessor.accessorSpecifier.tokenKind {
                case .keyword(.didSet), .keyword(.willSet): return true
                default: return false
                }
            }
        }
    }

    private static func resolvedType(at index: Int, in bindings: [PatternBindingSyntax]) -> TypeSyntax? {
        if let own = bindings[index].typeAnnotation?.type { return own }
        if bindings[index].initializer != nil { return nil }
        var cursor = index + 1
        while cursor < bindings.count {
            if let type = bindings[cursor].typeAnnotation?.type { return type }
            if bindings[cursor].initializer != nil { return nil }
            cursor += 1
        }
        return nil
    }

    private static func optionalInner(_ type: TypeSyntax) -> TypeSyntax? {
        if let optional = type.as(OptionalTypeSyntax.self) { return optional.wrappedType }
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.name.text == "Optional",
            case .type(let inner)? = identifier.genericArgumentClause?.arguments.first?.argument
        {
            return inner
        }
        return nil
    }

    // MARK: - Identifier and literal rendering

    private static func bareIdentifier(_ text: String) -> String {
        if text.count >= 2, text.hasPrefix("`"), text.hasSuffix("`") {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

}

enum TableMacroDiagnostic: DiagnosticMessage {
    case unsupportedDeclaration
    case noStoredProperties
    case requiresTypeAnnotation(String)
    case unsupportedType(String, String)

    var diagnosticID: MessageID {
        let id: String
        switch self {
        case .unsupportedDeclaration: id = "unsupportedDeclaration"
        case .noStoredProperties: id = "noStoredProperties"
        case .requiresTypeAnnotation: id = "requiresTypeAnnotation"
        case .unsupportedType: id = "unsupportedType"
        }
        return MessageID(domain: "ADSQLMacros.Table", id: id)
    }

    var severity: DiagnosticSeverity { .error }

    var message: String {
        switch self {
        case .unsupportedDeclaration:
            return "@Table can only be applied to a struct."
        case .noStoredProperties:
            return "@Table requires at least one stored property to form a table column."
        case .requiresTypeAnnotation(let name):
            return "@Table needs an explicit type annotation on stored property '\(name)'."
        case .unsupportedType(let name, let type):
            return
                "@Table does not support the type '\(type)' of property '\(name)'. Supported column "
                + "types are Int64, Int, Bool, String, Double, [UInt8], and a single optional layer."
        }
    }
}
