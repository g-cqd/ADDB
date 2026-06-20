@_spi(ADDBEngine) public import ADDBCore
import ADSQL
public import ADSQLModel

/// A typed error from validating a builder-assembled statement against a schema:
/// it surfaces the binder's semantic checks (unknown table/column, aggregate
/// misuse, type/affinity problems) ahead of execution, so a `Query` / write
/// builder can fail early with a precise message instead of at run time. Mirrors
/// URLBuilder's `URLBuildError` / `URLValidator` split.
public struct SQLBuildError: Error, CustomStringConvertible, Sendable {
    public let message: String
    /// The engine error the validation surfaced (nil for a builder-level problem).
    public let underlying: DBError?

    public init(_ underlying: DBError) {
        self.underlying = underlying
        self.message = "\(underlying)"
    }

    public init(message: String) {
        self.message = message
        self.underlying = nil
    }

    public var description: String { "SQL build error: \(message)" }
}

extension Query {
    /// Binds the lowered `SELECT` against `schema` (the binder's full semantic
    /// pass — table/column resolution, aggregate rules, collations) and throws a
    /// typed ``SQLBuildError`` if it doesn't hold. Returns normally for a valid
    /// query. Use it to validate a builder before running it (or in a test) without
    /// opening a write or materializing rows.
    public func validate(against schema: Schema) throws(SQLBuildError) {
        do throws(DBError) {
            try validateQuery(makeSelect(), schema: schema)
        } catch {
            throw SQLBuildError(error)
        }
    }

    /// Validates against the database's current committed schema (read in a
    /// snapshot). Convenience over ``validate(against:)-(Schema)``.
    public func validate(against db: Database) throws(SQLBuildError) {
        let schema: Schema
        do throws(DBError) {
            schema = try db.read { (txn) throws(DBError) in try txn.schema() }
        } catch {
            throw SQLBuildError(error)
        }
        try validate(against: schema)
    }
}
