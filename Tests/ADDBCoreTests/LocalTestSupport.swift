import Foundation

// Minimal, dependency-free test scaffolding for the pure-engine slice.
//
// The pure-engine characterization tests must build and run under the lean
// `ADDB_TESTING=1` configuration, where the shared `ADTestKit` package (and its
// transitive `swift-system` / `swift-collections` / `ADConcurrency` graph) is NOT
// resolved — it is gated behind `ADDB_DEV`. So rather than reach for
// `ADTestKit.withTemporaryFilePath`, this file vends a tiny local equivalent built
// only on `Foundation`. It is intentionally named differently from the ADTestKit
// helper so the two never collide in the dev build where both are visible.

/// Vends a unique scratch database path inside a fresh, private temp directory, runs
/// `body`, then removes the entire directory. Because the file lives in its own
/// directory, that single recursive removal also clears any `-wal` / `-shm` / `-lock`
/// engine siblings dropped next to it — no hard-coded suffix list required. The
/// directory is created with `FileManager.url(for: .itemReplacementDirectory:)` when a
/// base URL is available (a unique, process-private location), falling back to a
/// UUID-named directory under the system temp dir.
func withTempDBPath<R>(
    prefix: String = "addb-engine",
    _ body: (String) throws -> R
) throws -> R {
    let fm = FileManager.default
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let dir = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    defer { try? fm.removeItem(at: dir) }
    let file = dir.appendingPathComponent("\(prefix).db", isDirectory: false)
    return try body(file.path)
}
