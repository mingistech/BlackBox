// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "BlackBoxCore", platforms: [.macOS(.v14)], targets: [
    .target(name: "BlackBoxCore", path: "BlackBox/Core"),
    .testTarget(name: "BlackBoxCoreTests", dependencies: ["BlackBoxCore"], path: "Tests")
])
