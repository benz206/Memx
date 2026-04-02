// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MemoryStitcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MemoryStitcher",
            path: "Sources/MemoryStitcher",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
