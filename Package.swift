// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MemX",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "MemXCore",
            dependencies: [
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/MemX",
            exclude: ["Resources/Info.plist"]
        ),
        .executableTarget(
            name: "MemX",
            dependencies: ["MemXCore"],
            path: "Sources/MemXApp"
        ),
        .testTarget(
            name: "MemXTests",
            dependencies: ["MemXCore"],
            path: "Tests/MemXTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
