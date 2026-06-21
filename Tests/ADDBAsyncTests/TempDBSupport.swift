import ADSQLModel  // DBError (moved here in the ADSQL↔ADDB inversion)
import Foundation

// Minimal, dependency-free temp-database scaffolding for the async façade tests,
// mirroring ADDB's own `withTempDBPath` (the dev-gated ADTestKit graph is not
// resolved here). Each helper vends a unique scratch path inside its own private
// temp directory and recursively removes the directory afterwards, which also
// clears any `-wal` / `-lock` engine siblings without a hard-coded suffix list.

/// Async variant: vends a unique scratch DB path, runs the async `body`, then
/// removes the entire enclosing directory.
func withTempDBPath<R>(
    prefix: String = "addbasync",
    _ body: (String) async throws -> R
) async throws -> R {
    let fm = FileManager.default
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let dir = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    defer { try? fm.removeItem(at: dir) }
    let file = dir.appendingPathComponent("\(prefix).db", isDirectory: false)
    return try await body(file.path)
}

/// Encode an integer as 8 big-endian bytes — a convenient fixed-width value
/// payload for the concurrency tests.
func bytes(_ value: UInt64) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian) { Array($0) }
}

/// Inverse of ``bytes(_:)``: decode 8 big-endian bytes back to a `UInt64`, or
/// `nil` if the width is wrong.
func uint64(_ raw: [UInt8]) -> UInt64? {
    guard raw.count == 8 else { return nil }
    return raw.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
}

/// Encode an integer as a **user key**: a non-zero `0x01` marker byte followed by
/// the 8 big-endian value bytes. The leading marker keeps the key clear of the
/// engine's reserved `0x00` catalog prefix (small big-endian integers begin with
/// `0x00`, which the engine rejects as `DBError.reservedKey`), while the
/// big-endian tail preserves numeric ordering for the ordered cursor.
func key(_ value: UInt64) -> [UInt8] {
    [0x01] + bytes(value)
}
