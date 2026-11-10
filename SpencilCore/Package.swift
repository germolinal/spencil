// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpencilCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SpencilCore", targets: ["SpencilCore"])],
    targets: [
        .target(name: "SpencilCore"),
        .testTarget(name: "SpencilCoreTests", dependencies: ["SpencilCore"]),
    ]
)
