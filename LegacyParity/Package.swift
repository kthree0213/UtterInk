// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlowType",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FlowType", targets: ["FlowType"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.8.0")
    ],
    targets: [
        .executableTarget(
            name: "FlowType",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/FlowType",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                // 让 swift build / Xcode 直接跑二进制时也能读到 ATS 等键（与 .app 的 Contents/Info.plist 一致）。
                .unsafeFlags(
                    [
                        "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker",
                        "Sources/FlowType/Info.plist",
                    ],
                    .when(platforms: [.macOS])
                ),
            ]
        ),
        .testTarget(
            name: "FlowTypeTests",
            dependencies: ["FlowType"],
            path: "Tests/FlowTypeTests"
        )
    ]
)
