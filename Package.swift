// swift-tools-version: 6.4
import CompilerPluginSupport
import PackageDescription

// ADDB — the database ENGINE + execution. POST-INVERSION it DEPENDS ON the engine-free ADSQL frontend
// package (parser/binder/planner + the shared `ADSQLModel`). Targets:
//   • ADDBCore — pure storage engine + relational model (COW B+tree/mmap/MVCC, catalog, FTS index);
//     uses ADSQL's `ADSQLModel` (Value/Definitions/DBError).
//   • ADDBExec — the SQL executor/evaluator + trigger/scalar-fn execution; runs ADSQL's bound plan
//     over the concrete engine (concrete Value/Cursor → monomorphic, fast).
//   • ADDBFTS / ADDBJSON / ADDBMigrate / ADDBImport — opt-in supersets (renamed from the
//     interim ADSQL* names: the ADSQL prefix belongs to the separate frontend package, and these
//     modules ship from ADDB — consumers import the ADDB* names).
//   • ADDB — the curated public façade (engine + execution).
//   • ADDBAsync — the async façade over the engine's blocking read/writeSync (folded in from the
//     former standalone ADDBAsync package; offloads onto ADConcurrency.BlockingOffloadPool).
//   • ADDBMacros (+ the ADSQLMacros compiler plugin) — the opt-in @Table / #SQL sugar, isolated so
//     no shipped non-macro product links swift-syntax.
//   • ADSQLTool (the `adsql` CLI) and ADSQLBench (the vs-SQLite benchmark harness) — executables.
// The test suites (re-homed here from ADSQL in the inversion, plus the shared ADDBTestSupport
// fixture) and the ordo-one ADDBSuite benchmark are dev-gated behind ADDB_DEV=1 below — they pull
// dev-only dependencies (ADTestKit, ADBuildTools, ordo-one benchmark), so consumers resolving ADDB
// never see them.

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility")
]
let kernelSettings: [SwiftSetting] =
    strictSettings + [.strictMemorySafety(), .enableExperimentalFeature("Lifetimes")]

let isDev = Context.environment["ADDB_DEV"] != nil

func localOrMain(_ env: String, _ repo: String) -> Package.Dependency {
    if let path = Context.environment[env], !path.isEmpty { return .package(path: path) }
    return .package(url: "https://github.com/g-cqd/\(repo).git", branch: "main")
}

var packageDependencies: [Package.Dependency] = [
    localOrMain("ADSQL_PATH", "ADSQL"),
    localOrMain("ADFOUNDATION_PATH", "ADFoundation"),
    localOrMain("ADJSON_PATH", "ADJSON"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0")
]
if isDev {
    packageDependencies.append(localOrMain("ADBUILDTOOLS_PATH", "ADBuildTools"))
    // (ADTestKit is folded into ADFoundation; resolved via the ADFOUNDATION dependency above.)
    packageDependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"))
    // ordo-one's statistically-rigorous benchmark framework (p-percentile latencies + throughput +
    // malloc counts), matching the sibling ADFoundation / ADJSON suites. The suite lives in
    // `Benchmarks/ADDBSuite` and runs via `ADDB_DEV=1 swift package benchmark`. Dev-only, so packages
    // depending on ADDB never resolve it.
    packageDependencies.append(.package(url: "https://github.com/ordo-one/benchmark", from: "1.4.0"))
}
let adTestKit: Target.Dependency = .product(name: "ADTestKit", package: "ADFoundation")
let libraryBuildPlugins: [Target.PluginUsage] =
    isDev ? [.plugin(name: "LintBuild", package: "ADBuildTools")] : []

let adsqlModel: Target.Dependency = .product(name: "ADSQLModel", package: "ADSQL")
let adsql: Target.Dependency = .product(name: "ADSQL", package: "ADSQL")
let adfCore: Target.Dependency = .product(name: "ADFCore", package: "ADFoundation")
// Runtime-dispatched SIMD byte kernels (shared NOCASE ASCII fold).
let adfKernels: Target.Dependency = .product(name: "ADFKernels", package: "ADFoundation")
let adfIO: Target.Dependency = .product(name: "ADFIO", package: "ADFoundation")
let adfUnicode: Target.Dependency = .product(name: "ADFUnicode", package: "ADFoundation")
let adjsonCore: Target.Dependency = .product(name: "ADJSONCore", package: "ADJSON")
let orderedCollections: Target.Dependency = .product(name: "OrderedCollections", package: "swift-collections")
// swift-syntax runtime libraries — linked ONLY into test targets that exercise @Table, so the
// ADSQLMacros plugin's SwiftSyntax symbols resolve when the macro object is pulled into a test bundle.
let swiftSyntaxRuntime: [Target.Dependency] = [
    .product(name: "SwiftSyntax", package: "swift-syntax"),
    .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
    .product(name: "SwiftParser", package: "swift-syntax")
]

// Test targets are dev-only (they pull in the DEV-ONLY ADTestKit). The SQL-engine + integration
// suites (ADSQLTests, FTS/Import/Migrate) are re-homed here from the old ADSQL package incrementally;
// ADDBCoreTests (storage-engine characterization) is the first re-enabled guardrail.
// Test targets use a lighter setting set (no InternalImportsByDefault/MemberImportVisibility) — the
// re-homed suites carry broad `@testable` imports and the strict upcoming-feature gates only add
// import-bookkeeping noise with no safety value in test code.
let testSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
var testTargets: [Target] = []
if isDev {
    testTargets.append(
        .testTarget(
            name: "ADDBCoreTests",
            dependencies: ["ADDBCore", adsqlModel, adTestKit],
            swiftSettings: strictSettings))
    testTargets.append(
        .testTarget(
            name: "ADDBSmokeTests",
            dependencies: ["ADDB", adsqlModel, adTestKit],
            swiftSettings: strictSettings))
    // Expansion-level suite for the @Table / #SQL macros (assertMacroExpansion over the plugin
    // types): diagnostics + pass-through shape, which only exist at expansion time — the happy
    // path is integration-covered by ADSQLTests' TableMacroIntegrationTests. Depends on the
    // ADSQLMacros implementation target directly (macro targets build for the host, so the test
    // bundle links the macro types plus swift-syntax's swift-testing-native generic test support).
    testTargets.append(
        .testTarget(
            name: "ADDBMacrosTests",
            dependencies: [
                "ADSQLMacros",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax")
            ],
            swiftSettings: testSettings))
    // Folded in from the former standalone ADDBAsync package (self-contained — no ADTestKit/fixtures).
    testTargets.append(
        .testTarget(
            name: "ADDBAsyncTests",
            dependencies: [
                "ADDBAsync", "ADDB", adsqlModel, .product(name: "ADConcurrency", package: "ADFoundation")
            ],
            swiftSettings: strictSettings))
    // Shared fixture (MemKernel, ModelStore, SQLiteMirror, corpora) — a library target so the
    // re-homed suites can `@testable import` it. Re-homed from the old ADSQL package post-inversion.
    testTargets.append(
        .target(
            name: "ADDBTestSupport",
            dependencies: [
                "ADDBCore", "ADDBExec", "ADDBJSON", "CSQLite", adsql, adsqlModel, adTestKit
            ],
            path: "Tests/ADDBTestSupport",
            swiftSettings: testSettings))
    // The core SQL integration suite (DML/SELECT/joins/aggregates/triggers/…), now exercising the
    // executor in ADDBExec rather than ADSQL.
    testTargets.append(
        .testTarget(
            name: "ADSQLTests",
            dependencies: [
                "ADDBTestSupport", "ADDBCore", "ADDBExec", "ADDBMacros", "ADDBFTS",
                "ADDBJSON", "CSQLite", adsql, adsqlModel, adfCore, adfIO, adTestKit
            ] + swiftSyntaxRuntime,
            swiftSettings: testSettings))
    // The full-text-search query suite (MATCH / bm25 / WAND), exercising `ADDBFTS`.
    testTargets.append(
        .testTarget(
            name: "ADDBFTSTests",
            dependencies: [
                "ADDBTestSupport", "ADDBCore", "ADDBExec", "ADDBFTS", "CSQLite",
                adsql, adsqlModel, adfCore, adTestKit
            ],
            swiftSettings: testSettings))
    // The SQLite-import + apple-docs round-trip suite, exercising `ADDBImport`.
    testTargets.append(
        .testTarget(
            name: "ADDBImportTests",
            dependencies: [
                "ADDBTestSupport", "ADDBCore", "ADDBExec", "ADDBImport", "ADDBFTS",
                "ADDBJSON", "CSQLite", adsql, adsqlModel, adTestKit
            ],
            swiftSettings: testSettings))
    // The schema-migration suite, exercising `ADDBMigrate`.
    testTargets.append(
        .testTarget(
            name: "ADDBMigrateTests",
            dependencies: [
                "ADDBTestSupport", "ADDBCore", "ADDBExec", "ADDBMigrate", adsql, adsqlModel, adTestKit
            ],
            swiftSettings: testSettings))
    // ordo-one benchmark suite (ADDB_DEV-gated): tracks `.mallocCountTotal` on the storage codec path
    // (put/get/scan/index backfill) so a reintroduced copy-on-write copy or per-append reallocation
    // trips the threshold instead of rotting silently. Runs via `ADDB_DEV=1 swift package benchmark`.
    // Mirrors ADFoundation's `Benchmarks/ADFoundationSuite` wiring.
    testTargets.append(
        .executableTarget(
            name: "ADDBSuite",
            // ADDBExec adds the SQL executor (`prepare`/`Statement`/`all`/`run`) and
            // ADDBFTS the FTS evaluator (`openFTS`/`MATCH`/`bm25`) so the suite can
            // benchmark the SELECT + FTS hot paths (the in-process serving path), not just the
            // KV/relational primitives ADDBCore covers.
            dependencies: [
                "ADDBCore", "ADDBExec", "ADDBFTS",
                .product(name: "Benchmark", package: "benchmark")
            ],
            path: "Benchmarks/ADDBSuite",
            swiftSettings: strictSettings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]))
}

let package = Package(
    name: "ADDB",
    platforms: [.macOS(.v15), .iOS(.v26), .tvOS(.v26), .watchOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "ADDB", targets: ["ADDB"]),
        .library(name: "ADDBAsync", targets: ["ADDBAsync"]),
        .library(name: "ADDBCore", targets: ["ADDBCore"]),
        .library(name: "ADDBExec", targets: ["ADDBExec"]),
        .library(name: "ADDBMacros", targets: ["ADDBMacros"]),
        .library(name: "ADDBFTS", targets: ["ADDBFTS"]),
        .library(name: "ADDBJSON", targets: ["ADDBJSON"]),
        .library(name: "ADDBMigrate", targets: ["ADDBMigrate"]),
        .library(name: "ADDBImport", targets: ["ADDBImport"]),
        .executable(name: "adsql", targets: ["ADSQLTool"])
    ],
    dependencies: packageDependencies,
    targets: [
        .systemLibrary(name: "CSQLite"),
        // The @Table / #SQL compiler plugin (swift-syntax). Re-homed from ADSQL post-inversion so it
        // sits beside the @Table declaration (ADDBExec) it expands — the macro targets TableRow/SQLRow.
        .macro(
            name: "ADSQLMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "ADFMacroSupport", package: "ADFoundation")
            ],
            swiftSettings: strictSettings),
        .target(
            name: "ADDBCore", dependencies: [adfCore, adfKernels, adfIO, adfUnicode, adsqlModel],
            swiftSettings: kernelSettings, plugins: libraryBuildPlugins),
        .target(
            name: "ADDBExec", dependencies: ["ADDBCore", adsql, adsqlModel, orderedCollections],
            swiftSettings: kernelSettings, plugins: libraryBuildPlugins),
        // The @Table / #SQL macro sugar — an opt-in layer ABOVE the executor. Isolating the
        // ADSQLMacros (swift-syntax) plugin dependency here keeps it out of the core's link graph,
        // so engine / superset / test products never pull swift-syntax. `import ADDBMacros` to use it.
        .target(
            name: "ADDBMacros", dependencies: ["ADDBExec", "ADSQLMacros", adsqlModel],
            swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        .target(
            name: "ADDBFTS",
            dependencies: ["ADDBCore", "ADDBExec", adsql, adsqlModel, adfCore],
            swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        .target(
            name: "ADDBJSON", dependencies: ["ADDBCore", "ADDBExec", adsql, adsqlModel, adjsonCore],
            swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        .target(
            name: "ADDBMigrate", dependencies: ["ADDBCore", "ADDBExec", adsql, adsqlModel],
            swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        .target(
            name: "ADDBImport",
            dependencies: ["ADDBCore", "ADDBExec", adsql, adsqlModel, "CSQLite"],
            swiftSettings: strictSettings),
        .target(
            name: "ADDB", dependencies: ["ADDBCore", "ADDBExec", adsqlModel],
            swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        // ADDBAsync — async façade folded in from the former standalone package: offloads the engine's
        // blocking read/writeSync onto ADConcurrency.BlockingOffloadPool so a structured-concurrency
        // caller never blocks the cooperative pool. Consumes the engine via the public `ADDB` product;
        // this is what makes ADDB's previously-declared (and dead) ADConcurrency dependency live.
        .target(
            name: "ADDBAsync",
            dependencies: ["ADDB", adsqlModel, .product(name: "ADConcurrency", package: "ADFoundation")],
            swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        .executableTarget(
            name: "ADSQLTool",
            dependencies: ["ADDBCore", "ADDBExec", "ADDBImport", adsql, adsqlModel],
            swiftSettings: strictSettings),
        .executableTarget(
            name: "ADSQLBench",
            dependencies: [
                "ADDBCore", "ADDBExec", "ADDBFTS", "ADDBJSON", "CSQLite",
                adfIO, adsql, adsqlModel
            ],
            swiftSettings: strictSettings)
    ] + testTargets
)
