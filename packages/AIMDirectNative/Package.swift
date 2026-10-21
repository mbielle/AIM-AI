// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "AIMDirectNative", platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "AIMDirectNative", targets: ["AIMDirectNative"])],
    dependencies: [.package(path: "../AIMCore")],
    targets: [
        .binaryTarget(name: "AIMDataChannel", path: "Artifacts/AIMDataChannel.xcframework"),
        .target(name: "AIMDirectNative", dependencies: ["AIMDataChannel", .product(name: "AIMCore", package: "AIMCore")],
            linkerSettings: [.linkedLibrary("c++"), .linkedLibrary("pthread")])])
