// swift-tools-version: 6.3
import PackageDescription

// ADDB — the embedded database engine: storage (COW B+tree over mmap, MVCC), the
// relational model + catalog, and the full-text-search index. No SQL language and
// no JSON — those live in the separate `ADSQL` package, which consumes this
// engine through its `@_spi(ADDBEngine)` surface (the `ADDBCore` product exposes
// the engine module; the curated `public` API is re-exported by the `ADDB`
// product). The only dependency is the zero-dependency `ADFoundation` kernel.

// Opt-in warnings-as-errors gate: set `ADDB_WERROR=1` to compile every first-party
// target with `-warnings-as-errors`, while carving `StrictMemorySafety` back to a
// warning (the unsafe-construct shrink via `Span`/`MutableSpan` is in progress).
// Unset in consumer resolution, so the shipped library carries no unsafe flags and
// version-based dependency resolution keeps working.
let werrorSettings: [SwiftSetting] =
    Context.environment["ADDB_WERROR"] != nil
    ? [.unsafeFlags(["-warnings-as-errors", "-Wwarning", "StrictMemorySafety"])] : []

// Maximum strictness, shared across every target. Dependency-safe (no unsafe flags
// unless `ADDB_WERROR` is set). `.v6` turns on complete strict-concurrency checking;
// the upcoming features tighten existentials and import visibility.
let strictSettings: [SwiftSetting] =
    [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility")
    ] + werrorSettings

// Opt-in Instruments signposts: `ADDB_SIGNPOSTS=1` activates the (otherwise no-op)
// signpost helpers. A `.define` is a safe setting, so it never affects resolution.
let signpostSettings: [SwiftSetting] =
    Context.environment["ADDB_SIGNPOSTS"] != nil ? [.define("ADDB_SIGNPOSTS")] : []

// The kernel's safety model on top of `strictSettings`: SE-0458 strict memory
// safety (every unsafe construct is explicitly `unsafe`/`@safe`-encapsulated) plus
// experimental lifetime dependence (the scope-bounded page views are `~Escapable`
// over `RawSpan` with `@_lifetime`).
let kernelSettings: [SwiftSetting] =
    strictSettings + [
        .strictMemorySafety(),
        .enableExperimentalFeature("Lifetimes")
    ] + signpostSettings

// Compile-time type-check timing warnings (flag slow expressions / function bodies).
// Unsafe flags, so they live only on the internal (non-exported) test targets.
let timingWarningFlags: [SwiftSetting] = [
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=100",
        "-Xfrontend", "-warn-long-expression-type-checking=100"
    ])
]

// Tests: strict + timing warnings + runtime actor data-race checks.
let testSettings: [SwiftSetting] =
    strictSettings + timingWarningFlags + [.unsafeFlags(["-enable-actor-data-race-checks"])]

// Dev-only tooling is gated behind `ADDB_DEV` so packages that depend on ADDB never resolve it. The
// shared ADBuildTools `format` / `lint` / `LintBuild` plugins resolve only with the flag set (CI and the
// git hooks set it).
let isDev = Context.environment["ADDB_DEV"] != nil

// Opt-in `-enable-testing` for ADDBCore (`ADDB_TESTING=1`), so the separate ADSQL
// package's white-box tests can `@testable import ADDBCore` across the package boundary
// and reach engine `internal` symbols (the former single-package `@testable` access).
// Unsafe-flag-based, so it is gated: consumer/library builds leave it unset and the
// shipped engine carries no unsafe flags — version-based resolution keeps working.
let testingSettings: [SwiftSetting] =
    Context.environment["ADDB_TESTING"] != nil ? [.unsafeFlags(["-enable-testing"])] : []

// ADFoundation supplies the shared low-level primitives (`ADFCore` byte/number
// kernel, `ADFIO` POSIX storage). Resolve from a local checkout when
// `ADFOUNDATION_PATH` is set, otherwise from the published package.
let adfoundationDependency: Package.Dependency = {
    if let path = Context.environment["ADFOUNDATION_PATH"], !path.isEmpty {
        return .package(path: path)
    }
    return .package(url: "https://github.com/g-cqd/ADFoundation.git", branch: "main")
}()

var packageDependencies: [Package.Dependency] = [adfoundationDependency]
if isDev {
    // Shared lint/format tooling (Format/Lint/LintBuild plugins + canonical `.swift-format`). Dev-only,
    // resolved from a local checkout via `ADBUILDTOOLS_PATH`, otherwise the published `main` branch.
    if let path = Context.environment["ADBUILDTOOLS_PATH"], !path.isEmpty {
        packageDependencies.append(.package(path: path))
    } else {
        packageDependencies.append(
            .package(url: "https://github.com/g-cqd/ADBuildTools.git", branch: "main"))
    }
    packageDependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"))
    // ordo-one's statistically-rigorous benchmark framework (p-percentile latencies + malloc
    // metrics), matching the sibling ADFoundation/ADJSON suites. The suite lives in
    // `Benchmarks/ADDBSuite` and runs via `ADDB_DEV=1 swift package benchmark`. Dev-only, so
    // packages depending on ADDB never resolve it.
    packageDependencies.append(
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.4.0"))
}

let libraryBuildPlugins: [Target.PluginUsage] =
    isDev ? [.plugin(name: "LintBuild", package: "ADBuildTools")] : []

let package = Package(
    name: "ADDB",
    // macOS one generation below the device platforms (everything the engine needs —
    // `Synchronization`'s Atomic/Mutex ship in macOS 15, `Span`/`RawSpan` back-deploy
    // further still — is available there); device platforms at the 2025 generation.
    platforms: [
        .macOS(.v15),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        // The database product: a thin public façade that re-exports the engine's
        // curated `public` API for consumers who want the engine without SQL.
        .library(name: "ADDB", targets: ["ADDB"]),
        // The engine module itself. The separate `ADSQL` package links this and
        // imports its `@_spi(ADDBEngine)` surface (the broad engine API the SQL
        // layer drives). General consumers should prefer the `ADDB` façade.
        .library(name: "ADDBCore", targets: ["ADDBCore"])
    ],
    dependencies: packageDependencies,
    targets: [
        // ADDBCore — storage (COW B+tree over mmap, MVCC), relational model +
        // catalog, FTS index. Its `@_spi(ADDBEngine) public` surface is the broad
        // API the SQL layer consumes; `public` is the curated façade API.
        .target(
            name: "ADDBCore",
            dependencies: [
                .product(name: "ADFCore", package: "ADFoundation"),
                .product(name: "ADFIO", package: "ADFoundation")
            ],
            swiftSettings: kernelSettings + testingSettings,
            plugins: libraryBuildPlugins),
        // ADDB — thin public façade re-exporting ADDBCore's curated public API.
        .target(
            name: "ADDB",
            dependencies: ["ADDBCore"],
            swiftSettings: strictSettings,
            plugins: libraryBuildPlugins),
        // Engine characterization tests: pin the externally observable behavior of the
        // storage/relational engine so the package is verifiable on its own. The deep
        // coverage lives in the sibling ADSQL package's integration suite.
        .testTarget(
            name: "ADDBCoreTests",
            dependencies: ["ADDBCore"],
            swiftSettings: testSettings)

        // Format / lint / LintBuild come from the shared ADBuildTools dev dependency.
    ]
)

// ordo-one benchmark suite (ADDB_DEV-gated): allocation/throughput guards for the storage codec and
// CoW-sensitive paths so a reintroduced copy can't silently regress. Runs via
// `ADDB_DEV=1 swift package benchmark`.
if isDev {
    package.targets.append(
        .executableTarget(
            name: "ADDBSuite",
            dependencies: [
                "ADDBCore",
                .product(name: "Benchmark", package: "benchmark")
            ],
            path: "Benchmarks/ADDBSuite",
            swiftSettings: strictSettings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]))
}
