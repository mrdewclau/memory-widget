// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MemoryWidget",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MemoryWidget", targets: ["MemoryWidget"]),
        .executable(name: "ContextVisionHelper", targets: ["ContextVisionHelper"]),
        .executable(name: "ContextSoundHelper", targets: ["ContextSoundHelper"]),
        .executable(name: "MemoryWidgetMCP", targets: ["MemoryWidgetMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5")
    ],
    targets: [
        .executableTarget(
            name: "MemoryWidget",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("SwiftUI"),
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .executableTarget(
            name: "ContextVisionHelper",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(
            name: "ContextSoundHelper",
            linkerSettings: [
                .linkedFramework("SoundAnalysis")
            ]
        ),
        .executableTarget(name: "MemoryWidgetMCP")
    ]
)
