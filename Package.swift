// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UseMac",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "UseMacProtocol", targets: ["UseMacProtocol"]),
        .library(name: "UseMacEngine", targets: ["UseMacEngine"]),
        .library(name: "UseMacIPC", targets: ["UseMacIPC"]),
        .executable(name: "UseMac", targets: ["UseMacApp"]),
        .executable(name: "usemac", targets: ["UseMacCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .target(
            name: "UseMacProtocol",
            path: "Sources/UseMacProtocol",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "UseMacEngine",
            dependencies: ["UseMacProtocol"],
            path: "Sources/UseMacEngine",
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
            name: "UseMacIPC",
            dependencies: ["UseMacProtocol"],
            path: "Sources/UseMacIPC",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "UseMacApp",
            dependencies: [
                "UseMacProtocol",
                "UseMacEngine",
                "UseMacIPC",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/UseMacApp",
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
            name: "UseMacCLI",
            dependencies: ["UseMacProtocol", "UseMacEngine", "UseMacIPC"],
            path: "Sources/UseMacCLI",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "UseMacTests",
            dependencies: ["UseMacProtocol", "UseMacEngine", "UseMacIPC"],
            path: "Tests/UseMacTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
