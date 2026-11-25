// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacUse",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "MacUseProtocol", targets: ["MacUseProtocol"]),
        .library(name: "MacUseEngine", targets: ["MacUseEngine"]),
        .library(name: "MacUseIPC", targets: ["MacUseIPC"]),
        .executable(name: "MacUse", targets: ["MacUseApp"]),
        .executable(name: "macuse", targets: ["MacUseCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .target(
            name: "MacUseProtocol",
            path: "Sources/MacUseProtocol",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "MacUseEngine",
            dependencies: ["MacUseProtocol"],
            path: "Sources/MacUseEngine",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Network"),
                .linkedFramework("Vision")
            ]
        ),
        .target(
            name: "MacUseIPC",
            dependencies: ["MacUseProtocol"],
            path: "Sources/MacUseIPC",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "MacUseApp",
            dependencies: [
                "MacUseProtocol",
                "MacUseEngine",
                "MacUseIPC",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/MacUseApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon")
            ]
        ),
        .executableTarget(
            name: "MacUseCLI",
            dependencies: ["MacUseProtocol", "MacUseEngine", "MacUseIPC"],
            path: "Sources/MacUseCLI",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "MacUseTests",
            dependencies: ["MacUseProtocol", "MacUseEngine", "MacUseIPC"],
            path: "Tests/MacUseTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
