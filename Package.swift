// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AIUsage", path: "Sources/AIUsage"),
    ]
)
