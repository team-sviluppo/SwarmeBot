// swift-tools-version: 6.0
import PackageDescription

// SwarmeBot for macOS, native.
//
// Three layers, each testable without the one above it:
//
// - CompanionCore — the harness's wire types, SSE parser, API client and the
//   pure fold over stream frames. Copied from the iOS companion
//   (`SwarmeBot/ios/Sources/CompanionCore`) and extended with the fields a
//   desktop client needs; see docs/companion-core-divergence.md.
// - SwarmeKit — everything desktop-only that is still not a view: starting
//   and supervising the Node harness, the desktop-only routes, the
//   observable app model.
// - SwarmeBot — the SwiftUI app.
//
// macOS 14 is the floor: `@Observable`, `.inspector` and `scrollPosition`
// are what the UI is built on.
let package = Package(
    name: "SwarmeBot",
    // iOS is for AgentCore, CompanionCore and SwarmeL10n only, used by the iOS app in iOS/
    // (docs/plans/2026-10-22-app-ios.md); the other targets are macOS and Linux.
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        .executable(name: "SwarmeBot", targets: ["SwarmeBot"]),
        .library(name: "SwarmeBotUI", targets: ["SwarmeBotUI"]),
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
        .library(name: "SwarmeKit", targets: ["SwarmeKit"]),
        .library(name: "SwarmeL10n", targets: ["SwarmeL10n"]),
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "HarnessCore", targets: ["HarnessCore"]),
        .library(name: "HarnessRunner", targets: ["HarnessRunner"]),
        .executable(name: "swarme-harness", targets: ["swarme-harness"]),
        .executable(name: "swarme-push-relay", targets: ["swarme-push-relay"]),
    ],
    dependencies: [
        // Updates: signed appcast, EdDSA-verified archives.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // Linux only: CryptoKit's API for the remote engine (docs/plans/2026-10-16-bot-remoto.md §3.6)
        .package(url: "https://github.com/apple/swift-crypto", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "CompanionCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // UI languages and the Italian → English tables, for the Mac and iOS apps.
        .target(
            name: "SwarmeL10n",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "SwarmeKit",
            dependencies: ["CompanionCore", "SwarmeL10n"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app itself, as a library, so that an executable can pass the plugins
        // it is linked with (Plugins/AppPlugin.swift).
        .target(
            name: "SwarmeBotUI",
            dependencies: ["CompanionCore", "SwarmeKit", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The Code plugin, app side (macOS only: the iOS app has no Code mode). The core never imports it.
        .target(
            name: "CodePluginApp",
            dependencies: ["CompanionCore", "SwarmeKit", "SwarmeBotUI"],
            path: "Plugins/Code/App",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The Cylon plugin, app side (macOS only).
        .target(
            name: "CylonPluginApp",
            dependencies: ["CompanionCore", "SwarmeKit", "SwarmeBotUI"],
            path: "Plugins/Cylon/App",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // A thin shell: names the plugins and starts SwarmeBotUI.
        .executableTarget(
            name: "SwarmeBot",
            dependencies: ["SwarmeBotUI", "CodePluginApp", "CylonPluginApp"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Phase 2: the harness in Swift (docs/plans/fase-2-architettura.md).
        // the system libsqlite3 on Linux; macOS has the SQLite3 module built in
        // What the engine and the iOS app share: JSON, the MCP client over HTTP,
        // OAuth, OpenAI-compatible chat with Hermes continuity. No processes.
        .target(
            name: "AgentCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .systemLibrary(name: "CSQLite3", path: "Sources/CSQLite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(
            name: "HarnessCore",
            dependencies: [
                "AgentCore",
                .target(name: "CSQLite3", condition: .when(platforms: [.linux])),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "HarnessDrivers",
            dependencies: ["HarnessCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The engine's entry point as a library, so that an executable can pass the
        // plugins it is linked with (Sources/HarnessCore/Plugins.swift).
        .target(
            name: "HarnessRunner",
            dependencies: ["HarnessCore", "HarnessDrivers"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The Code plugin, engine side (git, branches, diff, commit of a chat's folder).
        // Builds on Linux too: it runs wherever the engine does. The core never imports it.
        .target(
            name: "CodePluginEngine",
            dependencies: ["HarnessCore"],
            path: "Plugins/Code/Engine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The Cylon plugin, engine side: the phases of a Cylon task in a channel. Builds on Linux too.
        .target(
            name: "CylonPluginEngine",
            dependencies: ["HarnessCore"],
            path: "Plugins/Cylon/Engine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "swarme-harness",
            dependencies: ["HarnessRunner", "CodePluginEngine", "CylonPluginEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The push relay for the iOS app (docs/plans/2026-10-22-app-ios.md §6.5): Linux and macOS.
        .executableTarget(
            name: "swarme-push-relay",
            dependencies: [
                "HarnessCore",
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HarnessCoreTests",
            dependencies: ["HarnessCore", "HarnessDrivers"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CodePluginEngineTests",
            dependencies: ["CodePluginEngine", "HarnessCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CylonPluginEngineTests",
            dependencies: ["CylonPluginEngine", "CodePluginEngine", "HarnessCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CodePluginAppTests",
            dependencies: ["CodePluginApp", "SwarmeBotUI", "CompanionCore", "SwarmeKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CylonPluginAppTests",
            dependencies: ["CylonPluginApp", "SwarmeBotUI", "CompanionCore", "SwarmeKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SwarmeBotUITests",
            dependencies: ["SwarmeBotUI", "CompanionCore", "SwarmeKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CompanionCoreTests",
            dependencies: ["CompanionCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SwarmeKitTests",
            dependencies: ["SwarmeKit", "CompanionCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
