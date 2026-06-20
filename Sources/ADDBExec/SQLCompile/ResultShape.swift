public import ADSQLModel

// Result-shape types. They belong with the frontend (the plan references the column header), and the
// executor — in the ADDB package's ADDBExec target — populates rows against them via `import ADSQL`.
// (Big-bang note: the duplicate definitions in ADDBExec/Statement.swift are removed when the engine
// side is wired.)

/// The column names of a query result, with case-insensitive name → index lookup.
public final class SQLColumnHeader: Sendable {
    public let names: [String]
    let indexByName: [String: Int]

    init(_ names: [String]) {
        self.names = names
        var map: [String: Int] = [:]
        for (index, name) in names.enumerated() {
            let key = name.lowercased()
            if map[key] == nil { map[key] = index }  // first occurrence wins
        }
        self.indexByName = map
    }
}

/// One result row: positional values plus the shared column header for name-based access.
public struct SQLRow: Sendable {
    public let header: SQLColumnHeader
    public let values: [Value]

    public var count: Int { values.count }
    public var columns: [String] { header.names }

    public subscript(_ index: Int) -> Value { values[index] }

    public subscript(_ name: String) -> Value? {
        header.indexByName[name.lowercased()].map { values[$0] }
    }
}
