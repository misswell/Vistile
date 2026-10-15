// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VistileCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VistileCore", targets: ["VistileCore"])
    ],
    targets: [
        .target(
            name: "VistileCore",
            path: "Sources/VistileCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "VistileCoreTests",
            dependencies: ["VistileCore"],
            path: "Tests/VistileCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
