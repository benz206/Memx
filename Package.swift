// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MemX",
    platforms: [.macOS(.v26)],
    dependencies: [],
    targets: [
        .target(
            name: "MemXCore",
            dependencies: [],
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
