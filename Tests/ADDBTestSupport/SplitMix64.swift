import ADSQLModel
// `@_exported` re-exports ADTestKit through ADDBTestSupport, so the ~20 dependent ADSQL
// suites that already `@testable import ADDBTestSupport` reach the kit's `SeededRNG` /
// `TemporaryDirectory` members under `MemberImportVisibility` without each file adding an
// `import ADTestKit` — i.e. they stay untouched. (A plain `public import` re-exports the
// types for signatures but not their members across modules, which SE-0444 rejects.)
@_exported import ADTestKit

@_spi(ADDBEngine) @testable import ADDBExec

/// The deterministic seedable RNG is now the shared `ADTestKit.SeededRNG`; this alias
/// keeps the dependent ADSQL test files calling `SplitMix64(seed:)` untouched while
/// removing the seventh hand-rolled copy. The SplitMix64 core stream is byte-identical,
/// so every pinned seed reproduces the same sequence after the migration.
public typealias SplitMix64 = ADTestKit.SeededRNG
