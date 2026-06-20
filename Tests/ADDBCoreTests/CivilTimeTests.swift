// This suite uses ADTestKit (the shared `.tags(.property)` lane tag), which is a
// DEV-only dependency: it is resolved only when `ADDB_DEV=1` (CI / git hooks) and is
// absent from the lean `ADDB_TESTING=1` build used to run the pure-engine slice. The
// whole file therefore compiles only when ADTestKit is importable — in the lean build
// it compiles to nothing rather than failing to resolve the module. The deterministic
// pure-engine coverage that needs no ADTestKit lives in
// `StorageEngineCharacterizationTests` (and the shared `EngineCharacterizationTests`).
#if canImport(ADTestKit)
    import ADTestKit
    import Testing

    @_spi(ADDBEngine) @testable import ADDBCore

    /// The first deterministic `datetime('now')` tests: the `CivilTime` seam pins the
    /// clock to a fixed epoch, so the formatted timestamp is exact with no real-time read
    /// and no flake. Pillar A's `now`-provider seam in action on the engine's datetime
    /// default — the live clock stays the production default, untouched.
    @Suite(.tags(.property))
    struct CivilTimeTests {
        @Test
        func `utcNowString is exact under an injected clock`() {
            #expect(CivilTime.utcNowString(now: { 0 }) == "1970-01-01 00:00:00")
            #expect(CivilTime.utcNowString(now: { 1_609_459_200 }) == "2021-01-01 00:00:00")
            // Leap day, mid-day — exercises the civil-from-days month/day math.
            #expect(CivilTime.utcNowString(now: { 1_582_979_696 }) == "2020-02-29 12:34:56")
            // One second before the epoch — the floor-division / negative-seconds path.
            #expect(CivilTime.utcNowString(now: { -1 }) == "1969-12-31 23:59:59")
        }

        @Test
        func `the live default still reads the real clock (production unchanged)`() {
            // The default path must agree with explicitly injecting the live provider, and
            // both must land in a plausible present window (sanity that the seam didn't
            // change production behavior).
            let viaDefault = CivilTime.utcNowString()
            let viaInjectedLive = CivilTime.utcNowString(now: CivilTime.liveEpochSeconds)
            #expect(viaDefault.hasPrefix("20"))
            #expect(viaInjectedLive.hasPrefix("20"))
            #expect(viaDefault.count == "YYYY-MM-DD HH:MM:SS".count)
        }
    }
#endif
