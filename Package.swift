// swift-tools-version: 6.2
// DBStudio workspace root.
//
// Every library lives under Packages/<Name> and the CLI harness under Tools/dbcli.
// A single root manifest gives one build graph, one `swift test`, and one local
// package reference for the Xcode app (see DECISIONS.md, ADR-0001).
//
// Dependency direction is strictly downward: App → DB* → DBCore.
// DBCore depends only on Foundation and swift-log. Drivers never import each other.
// `Scripts/ci.sh` lints `import` statements against the same rules.

import PackageDescription

/// Settings applied to every first-party target: Swift 6 language mode, which
/// implies `-strict-concurrency=complete`. "Zero warnings" is enforced by
/// `Scripts/ci.sh`, which recompiles first-party targets and fails on any warning
/// (Xcode builds packages with `-suppress-warnings`, so `.treatAllWarnings(as:)`
/// cannot live here — see DECISIONS.md ADR-0005).
let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "DBStudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DBCore", targets: ["DBCore"]),
        .library(name: "DBSQL", targets: ["DBSQL"]),
        .library(name: "DBPostgres", targets: ["DBPostgres"]),
        .library(name: "DBMySQL", targets: ["DBMySQL"]),
        .library(name: "DBTunnel", targets: ["DBTunnel"]),
        .library(name: "DBStore", targets: ["DBStore"]),
        .library(name: "DBTestKit", targets: ["DBTestKit"]),
        .executable(name: "dbcli", targets: ["dbcli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0"),
    ],
    targets: [
        // MARK: Libraries

        .target(
            name: "DBCore",
            dependencies: [.product(name: "Logging", package: "swift-log")],
            path: "Packages/DBCore/Sources/DBCore",
            swiftSettings: strict
        ),
        .target(
            name: "DBSQL",
            dependencies: ["DBCore"],
            path: "Packages/DBSQL/Sources/DBSQL",
            swiftSettings: strict
        ),
        .target(
            name: "DBPostgres",
            dependencies: [
                "DBCore",
                "DBSQL",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            path: "Packages/DBPostgres/Sources/DBPostgres",
            swiftSettings: strict
        ),
        .target(
            name: "DBMySQL",
            dependencies: ["DBCore"],
            path: "Packages/DBMySQL/Sources/DBMySQL",
            swiftSettings: strict
        ),
        .target(
            name: "DBTunnel",
            dependencies: [
                "DBCore",
                .product(name: "Citadel", package: "Citadel"),
            ],
            path: "Packages/DBTunnel/Sources/DBTunnel",
            swiftSettings: strict
        ),
        .target(
            name: "DBStore",
            dependencies: ["DBCore"],
            path: "Packages/DBStore/Sources/DBStore",
            swiftSettings: strict
        ),
        .target(
            name: "DBTestKit",
            dependencies: ["DBCore"],
            path: "Packages/DBTestKit/Sources/DBTestKit",
            swiftSettings: strict
        ),

        // MARK: Tools

        .executableTarget(
            name: "dbcli",
            dependencies: ["DBCore", "DBSQL", "DBPostgres", "DBMySQL", "DBTunnel", "DBStore"],
            path: "Tools/dbcli",
            swiftSettings: strict
        ),

        // MARK: Tests

        .testTarget(
            name: "DBCoreTests",
            dependencies: ["DBCore", "DBTestKit"],
            path: "Packages/DBCore/Tests/DBCoreTests",
            swiftSettings: strict
        ),
        .testTarget(
            name: "DBSQLTests",
            dependencies: ["DBSQL", "DBTestKit"],
            path: "Packages/DBSQL/Tests/DBSQLTests",
            swiftSettings: strict
        ),
        .testTarget(
            name: "DBPostgresTests",
            dependencies: ["DBPostgres", "DBTestKit"],
            path: "Packages/DBPostgres/Tests/DBPostgresTests",
            swiftSettings: strict
        ),
        .testTarget(
            name: "DBMySQLTests",
            dependencies: ["DBMySQL", "DBTestKit"],
            path: "Packages/DBMySQL/Tests/DBMySQLTests",
            swiftSettings: strict
        ),
        .testTarget(
            name: "DBTunnelTests",
            // DBPostgres is a *test-only* dependency here: the tunnel's acceptance
            // criterion is a real database reached through a real SSH forward, which is
            // exactly how the app composes the two. The DBTunnel library itself never
            // imports a driver, and Scripts/ci.sh checks that.
            dependencies: ["DBTunnel", "DBTestKit", "DBPostgres"],
            path: "Packages/DBTunnel/Tests/DBTunnelTests",
            swiftSettings: strict
        ),
        .testTarget(
            name: "DBStoreTests",
            dependencies: ["DBStore", "DBTestKit"],
            path: "Packages/DBStore/Tests/DBStoreTests",
            swiftSettings: strict
        ),
        .testTarget(
            name: "DBTestKitTests",
            dependencies: ["DBTestKit"],
            path: "Packages/DBTestKit/Tests/DBTestKitTests",
            swiftSettings: strict
        ),
    ]
)
