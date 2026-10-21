// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AIMCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AIMCore", targets: ["AIMCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(
            url: "https://github.com/supabase/supabase-swift.git",
            exact: "2.55.2"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-markdown.git",
            exact: "0.8.0"
        ),
        .package(
            url: "https://github.com/mgriebling/SwiftMath.git",
            exact: "1.7.3"
        ),
    ],
    targets: [
        .target(
            name: "AIMCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftMath", package: "SwiftMath"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "AIMCoreTests",
            dependencies: ["AIMCore"]
        ),
    ]
)
