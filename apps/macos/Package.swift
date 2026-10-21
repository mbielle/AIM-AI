// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AIMMac",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AIMMac", targets: ["AIMMac"]),
        .executable(name: "AIMAgentHost", targets: ["AIMAgentHost"]),
        .executable(name: "AIMProcessIntegrationQA", targets: ["AIMProcessIntegrationQA"]),
        .library(name: "AIMApplication", targets: ["AIMApplication"]),
        .library(name: "AIMAgentKit", targets: ["AIMAgentKit"]),
        .library(name: "AIMAgentRuntime", targets: ["AIMAgentRuntime"]),
        .library(name: "AIMMacPlatform", targets: ["AIMMacPlatform"]),
    ],
    dependencies: [
        .package(path: "../../packages/AIMCore"),
        .package(path: "../../packages/AIMDirectNative"),
        // Same exact version as AIMCore (one resolution); used directly by the Remote host.
        .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.55.2"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        // On-device dictation. WhisperKit (MIT): Whisper on Core ML. FluidAudio (Apache 2.0): Parakeet;
        // its optional prebuilt text-normalization binary is left out (no traits).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: []),
    ],
    targets: [
        .target(name: "AIMProcessSupport"),
        .executableTarget(name: "AIMProcessIntegrationQA", dependencies: ["AIMCore", "AIMAgentKit", "AIMMacPlatform"]),
        .target(
            name: "AIMApplication",
            dependencies: [
                "AIMCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "AIMAgentKit",
            dependencies: ["AIMApplication"]
        ),
        .target(
            name: "AIMMacPlatform",
            dependencies: [
                "AIMProcessSupport",
                "AIMApplication",
                "AIMAgentKit",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .target(name: "AIMAgentRuntime", dependencies: ["AIMCore", "AIMApplication", "AIMAgentKit", "AIMMacPlatform"]),
        .executableTarget(name: "AIMAgentHost", dependencies: ["AIMAgentRuntime", "AIMApplication", "AIMMacPlatform"]),
        .executableTarget(
            name: "AIMMac",
            dependencies: [
                "AIMCore",
                .product(name: "AIMDirectNative", package: "AIMDirectNative"),
                "AIMApplication",
                "AIMAgentKit",
                "AIMMacPlatform",
                "AIMAgentRuntime",
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AIMApplicationTests",
            dependencies: ["AIMApplication"]
        ),
        .testTarget(
            name: "AIMAgentKitTests",
            dependencies: ["AIMAgentKit"]
        ),
        .testTarget(
            name: "AIMMacPlatformTests",
            dependencies: ["AIMMacPlatform"]
        ),
        .testTarget(
            name: "AIMAgentRuntimeTests",
            dependencies: ["AIMAgentRuntime", "AIMApplication", "AIMAgentKit", "AIMMacPlatform"]
        ),
        .testTarget(
            name: "AIMMacTests",
            dependencies: ["AIMMac", "AIMAgentRuntime", "AIMApplication", "AIMCore", "AIMMacPlatform"]
        ),
    ]
)
