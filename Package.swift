// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TNT",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "TNT", targets: ["TNT"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMajor(from: "1.3.0")),
        .package(url: "https://github.com/ivan-digital/qwen3-asr-swift", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "TNT",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Qwen3ASR", package: "qwen3-asr-swift"),
                .product(name: "AudioCommon", package: "qwen3-asr-swift"),
            ],
            path: "Sources"
        )
    ]
)
