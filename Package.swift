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
    targets: [
        .executableTarget(
            name: "MemoryWidget",
            path: ".",
            sources: [
                "MemoryWidget.swift",
                "ContextObservatory.swift",
                "MCPStateBridge.swift"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "ContextVisionHelper",
            path: ".",
            sources: ["ContextVisionHelper.swift"],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(
            name: "ContextSoundHelper",
            path: ".",
            sources: ["ContextSoundHelper.swift"],
            linkerSettings: [
                .linkedFramework("SoundAnalysis")
            ]
        ),
        .executableTarget(
            name: "MemoryWidgetMCP",
            path: ".",
            sources: ["MemoryWidgetMCP.swift"]
        )
    ]
)
