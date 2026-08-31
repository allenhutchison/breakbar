// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreakBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BreakBar", targets: ["BreakBarApp"]),
        .library(name: "BreakBarCore", targets: ["BreakBarCore"]),
    ],
    targets: [
        .target(name: "BreakBarCore"),
        .executableTarget(
            name: "BreakBarApp",
            dependencies: ["BreakBarCore"]
        ),
        .testTarget(
            name: "BreakBarCoreTests",
            dependencies: ["BreakBarCore"]
        ),
    ]
)
