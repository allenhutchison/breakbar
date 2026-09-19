// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreakBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BreakBar", targets: ["BreakBarApp"]),
        .library(name: "BreakBarCore", targets: ["BreakBarCore"]),
        .library(name: "BreakBarBusyBar", targets: ["BreakBarBusyBar"]),
        .library(name: "BreakBarPersistence", targets: ["BreakBarPersistence"]),
        .library(name: "BreakBarExport", targets: ["BreakBarExport"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.10.0"
        ),
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            exact: "1.38.1"
        ),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "BreakBarCore"),
        .target(
            name: "BreakBarBusyBar",
            dependencies: [
                "BreakBarCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            resources: [
                .copy("Protos/swift-protobuf-config.json"),
            ],
            plugins: [
                .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf"),
            ]
        ),
        .target(
            name: "BreakBarPersistence",
            dependencies: ["BreakBarCore", "CSQLite"]
        ),
        .target(
            name: "BreakBarExport",
            dependencies: ["BreakBarPersistence"]
        ),
        .executableTarget(
            name: "BreakBarApp",
            dependencies: [
                "BreakBarCore",
                "BreakBarBusyBar",
                "BreakBarPersistence",
                "BreakBarExport",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .testTarget(
            name: "BreakBarCoreTests",
            dependencies: ["BreakBarCore"]
        ),
        .testTarget(
            name: "BreakBarBusyBarTests",
            dependencies: [
                "BreakBarCore",
                "BreakBarBusyBar",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "BreakBarPersistenceTests",
            dependencies: ["BreakBarCore", "BreakBarPersistence", "CSQLite"]
        ),
        .testTarget(
            name: "BreakBarExportTests",
            dependencies: ["BreakBarExport", "BreakBarPersistence"]
        ),
        .testTarget(
            name: "BreakBarAppTests",
            dependencies: ["BreakBarApp"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../../..",
                ]),
            ]
        ),
    ]
)
