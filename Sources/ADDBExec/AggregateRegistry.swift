@_spi(ADDBEngine) import ADDBCore
import ADSQL
package import ADSQLModel
import Synchronization

/// One group's running state for a custom (extension-registered) aggregate. The
/// core evaluates the aggregate's argument expressions against the live row and
/// hands the resulting values to ``update(_:)``; ``result()`` yields the group's
/// value at finalization. One instance per group per aggregate slot, used on the
/// executor thread that created it — not `Sendable`.
package protocol AggregateAccumulator: AnyObject {
    /// Folds one row's already-evaluated argument values into the running state.
    func update(_ args: [Value]) throws(DBError)
    /// The aggregate's value for the group.
    func result() -> Value
}

/// How a custom aggregate is recognized and accumulated: its accepted argument
/// arity (the binder rejects out-of-range / `*` calls) and a factory for a fresh
/// per-group accumulator.
package struct AggregateDescriptor: Sendable {
    package let argCount: ClosedRange<Int>
    package let makeAccumulator: @Sendable () -> any AggregateAccumulator

    package init(
        argCount: ClosedRange<Int>, makeAccumulator: @escaping @Sendable () -> any AggregateAccumulator
    ) {
        self.argCount = argCount
        self.makeAccumulator = makeAccumulator
    }
}

/// Process-wide registry of custom aggregate functions, keyed by UPPERCASE name.
/// The binder consults it to recognize an aggregate the core doesn't hardcode
/// (and to bind it to the `AggregateSpec.Kind.custom` slot); `GroupAccumulators`
/// consults it to build a per-group accumulator. Registration is idempotent and
/// one-way, matching ``SQLFunctionRegistry``. Extension modules (``ADDBJSON``)
/// register their group aggregates here on enable.
package enum SQLAggregateRegistry {
    private static let descriptors = Mutex<[String: AggregateDescriptor]>([:])

    /// Registers `descriptor` for `name` (case-insensitive) unless one is already
    /// present.
    package static func register(_ name: String, _ descriptor: AggregateDescriptor) {
        let key = name.uppercased()
        descriptors.withLock { if $0[key] == nil { $0[key] = descriptor } }
        // Mirror the arity into the binder's signature table so a custom aggregate is *bound*, not
        // just executed — the binder validates calls against `AggregateSignatures` before planning.
        AggregateSignatures.register(name, argCount: descriptor.argCount)
    }

    /// Convenience registration from an arity + accumulator factory.
    package static func register(
        _ name: String, argCount: ClosedRange<Int>,
        makeAccumulator: @escaping @Sendable () -> any AggregateAccumulator
    ) {
        register(name, AggregateDescriptor(argCount: argCount, makeAccumulator: makeAccumulator))
    }

    /// The descriptor for `name`, or nil when no custom aggregate is registered.
    /// Triggers one-time core-builtin registration first, so a lookup always sees
    /// the builtin set (plus any enabled extensions).
    package static func descriptor(for name: String) -> AggregateDescriptor? {
        SQLFunctions.ensureBuiltinsRegistered()
        return descriptors.withLock { $0[name.uppercased()] }
    }
}
