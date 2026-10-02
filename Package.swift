// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Openflow",
    platforms: [.macOS(.v14)],
    targets: [
        // UI-free pipeline: streaming STT, transcript assembly, VAD, Grok formatter, dictation state machine.
        .target(name: "OpenflowCore", swiftSettings: v5),
        // The menu bar app (hotkey, mic, overlay bubble, paste, settings, updates).
        .executableTarget(
            name: "Openflow",
            dependencies: ["OpenflowCore", "Sparkle"],
            swiftSettings: v5,
            // Sparkle.framework ships inside Openflow.app/Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Headless harness that streams real WAV audio through the same engine.
        .executableTarget(name: "openflow-cli", dependencies: ["OpenflowCore"], swiftSettings: v5),
        // Sparkle 2.10.0 (update framework); checksum matches Sparkle's published Package.swift.
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
        ),
    ]
)
