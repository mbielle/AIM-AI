// swift-tools-version: 6.2
// AIM's MLX engine: a small local server built with xcodebuild (Metal shaders) and bundled in
// AIM AI.app next to llama.cpp. AIM starts it only when an MLX model is chosen.
import PackageDescription

let package = Package(
    name: "AIMMLXEngine",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3"), traits: []),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "aim-mlx-engine",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ]
)
