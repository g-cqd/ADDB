package import ADDBCore
import Synchronization

/// The implementation of the JSON constructs the evaluator handles structurally —
/// the `->`/`->>` operators and `json_each(...)` membership — supplied by the
/// opt-in `ADSQLJSON` module (ADJSON-backed). A protocol witness, NOT a stored
/// closure: a `@Sendable` typed-throws closure put through a generic box hits a
/// reabstraction-thunk miscompile (infinite recursion → stack overflow), whereas a
/// witness-table call is well-defined — the same reason ``FTSEvaluation`` is a
/// protocol.
package protocol JSONOperatorEvaluator: Sendable {
    /// `document -> spec` (`asJSON == true`) / `document ->> spec` (text).
    func arrow(_ document: Value, _ spec: Value, asJSON: Bool) throws(DBError) -> Value
    /// The element values of `json_each(json)`.
    func eachValues(_ json: String) throws(DBError) -> [Value]
}

/// Process-wide registry for the JSON-operator evaluator, matching
/// ``SQLFunctionRegistry``. ADSQL core names no ADJSON type for `->`/`json_each`;
/// it calls through the registered witness (or throws a clear error if JSON is not
/// enabled). The compiled evaluator resolves the witness once at compile time.
package enum SQLJSONOperators {
    private static let box = Mutex<(any JSONOperatorEvaluator)?>(nil)

    /// Installs the evaluator (idempotent, first wins).
    package static func register(_ evaluator: any JSONOperatorEvaluator) {
        box.withLock { if $0 == nil { $0 = evaluator } }
    }

    /// The installed evaluator, or nil when JSON is not enabled. Triggers one-time
    /// builtin registration first (so a JSON-in-core build sees it without a prior
    /// function call).
    package static func evaluator() -> (any JSONOperatorEvaluator)? {
        SQLFunctions.ensureBuiltinsRegistered()
        return box.withLock { $0 }
    }

    package static func arrow(_ document: Value, _ spec: Value, asJSON: Bool) throws(DBError) -> Value {
        guard let evaluator = evaluator() else {
            throw DBError.sqlUnsupported("JSON operators (->, ->>): import ADSQLJSON and call enableJSON()")
        }
        return try evaluator.arrow(document, spec, asJSON: asJSON)
    }

    package static func eachValues(_ json: String) throws(DBError) -> [Value] {
        guard let evaluator = evaluator() else {
            throw DBError.sqlUnsupported("json_each: import ADSQLJSON and call enableJSON()")
        }
        return try evaluator.eachValues(json)
    }
}
