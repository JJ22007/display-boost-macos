// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "DisplayBoost",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DisplayBoost", targets: ["DisplayBoost"])
    ],
    targets: [
        .executableTarget(
            name: "DisplayBoost",
            path: "Sources/DisplayBoost"
        )
    ]
)
