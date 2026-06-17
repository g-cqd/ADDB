package import ADDBCore
import Synchronization

/// A scalar SQL function handler: it evaluates its argument expressions through
/// `env` (wired to the live row) and returns the result. `star` marks an `f(*)`
/// call; `offset` is the call's source offset (diagnostics). Extension modules
/// register handlers by name to add functions without touching core dispatch.
package typealias SQLScalarHandler =
    @Sendable (
        _ args: [SQLExpr], _ star: Bool, _ offset: Int, _ env: SQLEvalEnv
    ) throws(DBError) -> Value

/// Process-wide registry of scalar SQL functions, keyed by UPPERCASE name. Both
/// evaluators resolve a call through it: the compiled evaluator once at compile
/// time (so the hot path carries the captured handler — no per-row lookup), the
/// tree-walk evaluator per call. Registration is idempotent and one-way (these
/// functions are dialect-stateless), so the map is effectively immutable once the
/// core builtins and any enabled extension modules (``ADSQLJSON``) have registered.
/// Per-process, matching the stateless dialect model.
package enum SQLFunctionRegistry {
    private static let handlers = Mutex<[String: SQLScalarHandler]>([:])

    /// Registers `handler` for `name` (case-insensitive) unless one is already
    /// present (idempotent; first registration wins).
    package static func register(_ name: String, _ handler: @escaping SQLScalarHandler) {
        let key = name.uppercased()
        handlers.withLock { if $0[key] == nil { $0[key] = handler } }
    }

    /// The handler for `name`, or nil when no function (builtin or enabled
    /// extension) is registered under it. Triggers one-time core-builtin
    /// registration first, so a lookup always sees at least the core scalars.
    package static func handler(for name: String) -> SQLScalarHandler? {
        SQLFunctions.ensureBuiltinsRegistered()
        return handlers.withLock { $0[name.uppercased()] }
    }
}
