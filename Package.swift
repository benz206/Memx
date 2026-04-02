// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MemX",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MemX",
            path: "Sources/MemX"
        )
    ]
)
