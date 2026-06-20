import Synchronization

/// Frontend-visible signatures of custom (extension-registered) aggregates: name → accepted argument
/// arity. The binder validates a custom-aggregate call against this WITHOUT the engine's accumulator
/// factory (which stays in the ADDB package's `ADDBExec.SQLAggregateRegistry`). The execution side
/// registers each aggregate's arity here and installs `prepareHook` so a first lookup triggers the
/// lazy builtin registration.
///
/// Big-bang note: the engine-side wiring — `SQLAggregateRegistry.register` also calling
/// `AggregateSignatures.register`, and `SQLFunctions.ensureBuiltinsRegistered` installed via
/// `installPrepareHook` — is added when the executor is reconnected. Until then custom aggregates
/// bind only after their arity is registered.
public enum AggregateSignatures {
    private struct State {
        var arities: [String: ClosedRange<Int>] = [:]
        var prepareHook: (@Sendable () -> Void)?
    }
    private static let state = Mutex(State())

    /// Registers `name`'s accepted argument arity (idempotent, case-insensitive).
    public static func register(_ name: String, argCount: ClosedRange<Int>) {
        let key = name.uppercased()
        state.withLock { if $0.arities[key] == nil { $0.arities[key] = argCount } }
    }

    /// Installs the one-time builtin-registration trigger the execution side owns.
    public static func installPrepareHook(_ hook: @escaping @Sendable () -> Void) {
        state.withLock { if $0.prepareHook == nil { $0.prepareHook = hook } }
    }

    /// The accepted arity for a registered custom aggregate `name`, or nil if not registered. Runs
    /// the prepare hook (outside the lock, so the hook may itself register) before the lookup.
    public static func argCount(for name: String) -> ClosedRange<Int>? {
        let hook = state.withLock { $0.prepareHook }
        hook?()
        return state.withLock { $0.arities[name.uppercased()] }
    }
}
