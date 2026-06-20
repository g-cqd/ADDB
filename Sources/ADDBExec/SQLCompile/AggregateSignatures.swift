import Synchronization

/// The binder's view of custom (extension-registered) aggregates: name → accepted argument arity. The
/// binder validates a custom-aggregate call against this *signature* table before planning, separately
/// from the executor's accumulator factory in ``SQLAggregateRegistry``. The two stay in sync because
/// `SQLAggregateRegistry.register` mirrors every aggregate's arity here on registration (e.g. when
/// `ADSQLJSON.enableJSON()` registers `json_group_array`), so a custom aggregate *binds* as soon as
/// it's enabled. `installPrepareHook` lets the execution side trigger lazy builtin registration on a
/// first lookup if needed.
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
