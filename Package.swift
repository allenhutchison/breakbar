// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreakBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BreakBar", targets: ["BreakBarApp"]),
        .library(name: "BreakBarCore", targets: ["BreakBarCore"]),
        .library(name: "BreakBarPersistence", targets: ["BreakBarPersistence"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "BreakBarCore"),
        .target(
            name: "BreakBarPersistence",
            dependencies: ["BreakBarCore", "CSQLite"]
        ),
        .executableTarget(
            name: "BreakBarApp",
            dependencies: ["BreakBarCore", "BreakBarPersistence"]
        ),
        .testTarget(
            name: "BreakBarCoreTests",
            dependencies: ["BreakBarCore"]
        ),
        .testTarget(
            name: "BreakBarPersistenceTests",
            dependencies: ["BreakBarCore", "BreakBarPersistence", "CSQLite"]
        ),
        .testTarget(
            name: "BreakBarAppTests",
            dependencies: ["BreakBarApp"]
        ),
    ]
)
