// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UtterInkKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UtterInkCore", targets: ["UtterInkCore"]),
        .library(name: "UtterInkServices", targets: ["UtterInkServices"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.4.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "0.18.0")
    ],
    targets: [
        .target(name: "UtterInkCore"),
        .target(
            name: "UtterInkServices",
            dependencies: [
                "UtterInkCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        ),
        .testTarget(name: "UtterInkCoreTests", dependencies: ["UtterInkCore"]),
        .testTarget(name: "UtterInkServicesTests", dependencies: ["UtterInkCore", "UtterInkServices"])
    ]
)
