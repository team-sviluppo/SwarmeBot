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
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
        .library(name: "SwarmeKit", targets: ["SwarmeKit"]),
        .library(name: "SwarmeL10n", targets: ["SwarmeL10n"]),
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "HarnessCore", targets: ["HarnessCore"]),
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
        .executableTarget(
            name: "SwarmeBot",
            dependencies: ["CompanionCore", "SwarmeKit", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")],
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
        .executableTarget(
            name: "swarme-harness",
            dependencies: ["HarnessCore", "HarnessDrivers"],
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
