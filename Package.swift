// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Citadel",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Citadel", targets: ["Citadel"])],
    targets: [
        .target(name: "GitCore"),
        .executableTarget(name: "CitadelGitWorker"),
        .executableTarget(name: "CitadelGitEditor"),
        .executableTarget(name: "Citadel", dependencies: ["GitCore"]),
        .testTarget(name: "GitCoreTests", dependencies: ["GitCore"])
    ]
)
