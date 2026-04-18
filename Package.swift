// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MemX",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MemXCore",
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
    ]
)
