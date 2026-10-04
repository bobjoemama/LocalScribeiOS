// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalScribeCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "LocalScribeCore", targets: ["LocalScribeCore"])],
    targets: [
        .target(name: "LocalScribeCore"),
        .testTarget(name: "LocalScribeCoreTests", dependencies: ["LocalScribeCore"])
    ]
)
