import ADTestKit
import Foundation

// Shared support for the DEPTH-SWEEPING tests (cap-legal 200–250-term boolean chains and the
// seeded query fuzz), which recurse the binder/evaluator once per term by design.
//
// Why these tests pin their own thread: uninstrumented, a cap-legal ~250-deep
// `Binder.bindColumns` walk uses ~300 KiB — it fits the 512 KiB cooperative-pool stack
// swift-testing runs on, with ~1.7x margin. ASan redzones / TSan shadow frames inflate native
// frames ~3x (~825 KiB measured for the same walk), so the sanitizer legs died on the stack
// GUARD page (signal 4, no sanitizer report) for queries the depth caps deliberately ALLOW.
// Each sweep therefore runs on an explicitly sized thread: 512 KiB uninstrumented — the
// family's worker-stack floor, which turns the previously *incidental* production-margin proof
// into a deliberate one — and 4 MiB under a sanitizer, where the frame constant no longer
// models production. The property these tests pin — reject past-cap, accept under-cap — is
// stack-size-independent.
let depthSweepStackSize: Int = {
    // Runtime probe: the sanitizer runtimes export their initializers; dlsym through the
    // process's own global scope finds them iff this run is instrumented.
    let handle = dlopen(nil, RTLD_LAZY)
    defer { if handle != nil { dlclose(handle) } }
    let sanitized = dlsym(handle, "__asan_init") != nil || dlsym(handle, "__tsan_init") != nil
    return sanitized ? 4 * 1024 * 1024 : 512 * 1024
}()

/// Runs `body` on a dedicated `depthSweepStackSize` thread and ferries its typed result (or
/// error) back to the caller. Assert on the RETURNED value from the test task — `#expect`
/// inside `body` would record outside the current test (task-locals do not follow a raw
/// thread). Returning at all is the no-overflow half of the assertion, per
/// `runOnConstrainedStack`'s contract.
func runDepthSweep<R: Sendable>(_ body: @escaping @Sendable () throws -> R) throws -> R {
    try runOnConstrainedStack(stackSize: depthSweepStackSize, name: "ADSQLTests.depth-sweep") {
        Result { try body() }
    }.get()
}
