// swift-tools-version: 6.4
import PackageDescription

// ADDB — the database ENGINE + execution. POST-INVERSION it DEPENDS ON the engine-free ADSQL frontend
// package (parser/binder/planner + the shared `ADSQLModel`). Targets:
//   • ADDBCore — pure storage engine + relational model (COW B+tree/mmap/MVCC, catalog, FTS index);
//     uses ADSQL's `ADSQLModel` (Value/Definitions/DBError).
//   • ADDBExec — the SQL executor/evaluator + trigger/scalar-fn execution; runs ADSQL's bound plan
//     over the concrete engine (concrete Value/Cursor → monomorphic, fast).
//   • ADSQLFullTextSearch / ADSQLJSON / ADSQLMigrate / ADSQLImport — opt-in supersets (product names
//     preserved, so consumers' imports are unchanged — they just resolve from this package now).
//   • ADDB — the curated public façade (engine + execution).
// Big-bang note: ADDBAsync folds in + the ADStorageCore/ADDBEngine target split + the test split are
// the remaining steps (design doc §7–§8). Test/benchmark targets are temporarily omitted.

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
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
    localOrMain("ADCONCURRENCY_PATH", "ADConcurrency"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0")
]
if isDev {
    packageDependencies.append(localOrMain("ADBUILDTOOLS_PATH", "ADBuildTools"))
    packageDependencies.append(localOrMain("ADTESTKIT_PATH", "ADTestKit"))
    packageDependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"))
}
let adTestKit: Target.Dependency = .product(name: "ADTestKit", package: "ADTestKit")
let libraryBuildPlugins: [Target.PluginUsage] =
    isDev ? [.plugin(name: "LintBuild", package: "ADBuildTools")] : []

let adsqlModel: Target.Dependency = .product(name: "ADSQLModel", package: "ADSQL")
let adsql: Target.Dependency = .product(name: "ADSQL", package: "ADSQL")
let adfCore: Target.Dependency = .product(name: "ADFCore", package: "ADFoundation")
let adfIO: Target.Dependency = .product(name: "ADFIO", package: "ADFoundation")
let adjsonCore: Target.Dependency = .product(name: "ADJSONCore", package: "ADJSON")
let orderedCollections: Target.Dependency = .product(name: "OrderedCollections", package: "swift-collections")

// Test targets are dev-only (they pull in the DEV-ONLY ADTestKit). The SQL-engine + integration
// suites (ADSQLTests, FTS/Import/Migrate) are re-homed here from the old ADSQL package incrementally;
// ADDBCoreTests (storage-engine characterization) is the first re-enabled guardrail.
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
}

let package = Package(
    name: "ADDB",
    platforms: [.macOS(.v15), .iOS(.v26), .tvOS(.v26), .watchOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "ADDB", targets: ["ADDB"]),
        .library(name: "ADDBCore", targets: ["ADDBCore"]),
        .library(name: "ADDBExec", targets: ["ADDBExec"]),
        .library(name: "ADSQLFullTextSearch", targets: ["ADSQLFullTextSearch"]),
        .library(name: "ADSQLJSON", targets: ["ADSQLJSON"]),
        .library(name: "ADSQLMigrate", targets: ["ADSQLMigrate"]),
        .library(name: "ADSQLImport", targets: ["ADSQLImport"]),
        .executable(name: "adsql", targets: ["ADSQLTool"])
    ],
    dependencies: packageDependencies,
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "ADDBCore", dependencies: [adfCore, adfIO, adsqlModel],
            swiftSettings: kernelSettings, plugins: libraryBuildPlugins),
        .target(
            name: "ADDBExec", dependencies: ["ADDBCore", adsql, adsqlModel, orderedCollections],
            swiftSettings: kernelSettings, plugins: libraryBuildPlugins),
        .target(
            name: "ADSQLFullTextSearch",
            dependencies: ["ADDBCore", "ADDBExec", adsql, adsqlModel, adfCore],
            swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        .target(
            name: "ADSQLJSON", dependencies: ["ADDBCore", "ADDBExec", adsql, adsqlModel, adjsonCore],
            swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        .target(
            name: "ADSQLMigrate", dependencies: ["ADDBCore", "ADDBExec", adsql, adsqlModel],
            swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        .target(
            name: "ADSQLImport",
            dependencies: ["ADDBCore", "ADDBExec", adsql, adsqlModel, "CSQLite"],
            swiftSettings: strictSettings),
        .target(
            name: "ADDB", dependencies: ["ADDBCore", "ADDBExec"],
            swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        .executableTarget(
            name: "ADSQLTool",
            dependencies: ["ADDBCore", "ADDBExec", "ADSQLImport", adsql, adsqlModel],
            swiftSettings: strictSettings),
        .executableTarget(
            name: "ADSQLBench",
            dependencies: [
                "ADDBCore", "ADDBExec", "ADSQLFullTextSearch", "ADSQLJSON", "CSQLite",
                adfIO, adsql, adsqlModel
            ],
            swiftSettings: strictSettings)
    ] + testTargets
)
