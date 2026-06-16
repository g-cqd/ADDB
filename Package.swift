// swift-tools-version: 6.3
import PackageDescription

// Opt-in warnings-as-errors gate: set `ADSQL_WERROR=1` to compile every first-party target with
// `-warnings-as-errors`. It is unsafe-flag-based, but folding it into `strictSettings` is still
// dependency-safe: a consumer resolves this manifest with `ADSQL_WERROR` unset, so the array is empty
// and the shipped library carries no unsafe flags (version resolution keeps working). Target-scoped
// settings never reach ADJSON/swift-syntax/swift-collections, and the flag pulls in no extra
// dependency, so the committed `Package.resolved` stays accurate. (Passing `-warnings-as-errors` on
// the `swift build` CLI instead would also fail on dependency warnings outside our control.)
//
// `StrictMemorySafety` is carved back to a warning (`-Wwarning`): `.strictMemorySafety` flags every
// unmarked unsafe construct, and shrinking that surface (via `Span`/`MutableSpan`/`InlineArray`) is a
// tracked, in-progress effort rather than a one-shot `unsafe`-annotation sweep. So the gate errors on
// every *other* diagnostic group (deprecations, unused results, implicit Sendable, …) while the
// memory-safety diagnostics stay visible as warnings until that migration lands.
//
// Not yet wired into CI: warning emission is toolchain-dependent — some toolchains additionally emit
// spurious, group-less `will never be executed` SILGen diagnostics on the typed-throws/`Never`
// patterns (`throwErrno` etc.), which `-Wwarning` cannot selectively downgrade. CI will set
// `ADSQL_WERROR=1` once the toolchain is pinned to a release verified warning-clean (see the CI
// toolchain-pinning work), so the gate is deterministic rather than a moving target.
let werrorSettings: [SwiftSetting] =
    Context.environment["ADSQL_WERROR"] != nil
    ? [.unsafeFlags(["-warnings-as-errors", "-Wwarning", "StrictMemorySafety"])] : []

// Maximum strictness, shared across every Swift target. Dependency-safe (no unsafe flags unless
// `ADSQL_WERROR` is set, see above), so the library can still be consumed via a version-pinned
// SwiftPM requirement. `.v6` language mode turns on complete strict-concurrency checking; the
// upcoming features tighten existentials and import visibility. Aligned with the sibling
// `../adjson` package.
let strictSettings: [SwiftSetting] =
    [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
    ] + werrorSettings

// The kernel's safety model, on top of `strictSettings`: SE-0458 strict memory safety (every unsafe
// construct is explicitly `unsafe` or `@safe`-encapsulated, so any new unsafe use is compiler-flagged)
// plus experimental lifetime dependence (SE-0446/0456) — the scope-bounded page views are
// `~Escapable` over `RawSpan` with `@_lifetime`, so the compiler enforces they cannot outlive their
// snapshot.
let kernelSettings: [SwiftSetting] =
    strictSettings + [
        .strictMemorySafety(),
        .enableExperimentalFeature("Lifetimes"),
    ]

// Compile-time type-check timing warnings (flag slow expressions / function bodies). These use unsafe
// flags, which would block version-based dependency resolution if placed on the shipped library, so
// they live only on the internal (non-exported) benchmark + test targets.
let timingWarningFlags: [SwiftSetting] = [
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=100",
        "-Xfrontend", "-warn-long-expression-type-checking=100",
    ])
]

// Benchmarks: strict + timing warnings only (no runtime instrumentation, so timings stay clean).
let benchSettings: [SwiftSetting] = strictSettings + timingWarningFlags

// Tests: additionally enable runtime actor data-race checks.
let testSettings: [SwiftSetting] =
    strictSettings + timingWarningFlags + [.unsafeFlags(["-enable-actor-data-race-checks"])]

// Dev-only tooling is gated behind `ADSQL_DEV` so packages that depend on ADSQL never resolve it.
// The `format` / `lint` command plugins carry no external dependencies, so they are always available
// without the flag; build-time lint enforcement (the `LintBuild` plugin) attaches to the library only
// in dev/CI.
let isDev = Context.environment["ADSQL_DEV"] != nil

// ADSQL's only runtime dependency is the ADJSON package — specifically its Foundation-free,
// swift-syntax-free `ADJSONCore` product, which backs the SQL JSON functions (tape parser +
// SQLite-dialect path evaluator). The DocC plugin that builds the documentation site is dev/CI-only
// (gated behind ADSQL_DEV), so packages that depend on ADSQL never resolve it.
//
// Pinned to an exact revision (ADJSON publishes no version tags and tracks `main`): a floating
// branch would let an upstream change silently alter ADSQL between builds. The committed
// `Package.resolved` locks this revision and the transitive graph (swift-collections, swift-syntax)
// so dev/CI builds are reproducible; consumers that depend on ADSQL still resolve their own graph.
var packageDependencies: [Package.Dependency] = [
    .package(
        url: "https://github.com/g-cqd/ADJSON.git",
        revision: "82d516584d72a404b5fef0d6b0ccd295e139f156")
]
if isDev {
    packageDependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"))
}

let package = Package(
    name: "ADSQL",
    // Floor OSes match the sibling `../adjson` package: macOS one generation below the device
    // platforms (everything the engine needs — `Synchronization`'s Atomic/Mutex ship in macOS 15,
    // `Span`/`RawSpan` back-deploy further still — is available there), device platforms at the 2025
    // generation. No `@available`/2025-SDK-gated APIs are used, so the macOS-15 floor compiles.
    platforms: [
        .macOS(.v15),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26),
    ],
    products: [
        .library(name: "ADSQL", targets: ["ADSQL"]),
        .library(name: "ADSQLImport", targets: ["ADSQLImport"]),
        .library(name: "ADSQLSearch", targets: ["ADSQLSearch"]),
        .executable(name: "adsql", targets: ["ADSQLTool"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(name: "ADCAtomics"),
        .target(
            name: "ADSQLKernel",
            dependencies: ["ADCAtomics", .product(name: "ADJSONCore", package: "ADJSON")],
            swiftSettings: kernelSettings),
        .target(
            name: "ADSQL", dependencies: ["ADSQLKernel"], swiftSettings: strictSettings,
            plugins: isDev ? ["LintBuild"] : []),
        .executableTarget(
            name: "ADSQLTool", dependencies: ["ADSQL", "ADSQLImport"], swiftSettings: strictSettings),
        .systemLibrary(name: "CSQLite"),
        // SQLite-file importer: reads a source.db via CSQLite and writes an
        // ADSQL database. Kept out of ADSQLKernel so the read-only engine never links sqlite3.
        .target(
            name: "ADSQLImport", dependencies: ["ADSQLKernel", "CSQLite"], swiftSettings: strictSettings),
        // apple-docs search-pages serving: builds the §2.2 main query, binds the
        // §2.4 filter bag, and frames the §2.3 projection into the §2.5 response bytes — the Swift body
        // of apple-docs' frozen `ad_storage_search_pages` ABI. Depends on ADSQL only (NOT CSQLite), so it
        // stays link-clean exactly like the read engine.
        .target(
            name: "ADSQLSearch", dependencies: ["ADSQL"], swiftSettings: strictSettings),
        // ADSQLSearch is a bench dependency so the `search` scenario can call the real
        // `searchPagesFramed` / `SearchQuery` hot path it benchmarks against
        // system SQLite running the IDENTICAL `SearchQuery.sql` + `SearchQuery.bindings`.
        .executableTarget(
            name: "ADSQLBench", dependencies: ["ADSQL", "ADSQLSearch", "CSQLite"],
            swiftSettings: benchSettings),
        .target(
            name: "ADSQLTestSupport",
            dependencies: ["ADSQLKernel"],
            path: "Tests/ADSQLTestSupport",
            swiftSettings: testSettings
        ),
        .testTarget(
            name: "ADSQLKernelTests",
            dependencies: ["ADSQLKernel", "ADSQLTestSupport", "CSQLite"],
            swiftSettings: testSettings
        ),
        .testTarget(
            name: "ADSQLImportTests",
            dependencies: ["ADSQLImport", "ADSQLSearch", "ADSQLTestSupport", "CSQLite"],
            swiftSettings: testSettings
        ),

        // Developer tooling. The command plugins are dependency-free (they drive the toolchain's
        // bundled `swift format`), so they impose nothing on packages that depend on ADSQL.
        .plugin(
            name: "Format",
            capability: .command(
                intent: .custom(verb: "format", description: "Format Swift sources with swift-format"),
                permissions: [.writeToPackageDirectory(reason: "Format Swift sources with swift-format")])),
        .plugin(
            name: "Lint",
            capability: .command(
                intent: .custom(verb: "lint", description: "Check formatting (swift-format strict)"))),
        .plugin(name: "LintBuild", capability: .buildTool()),
    ]
)
