// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "SwiftAsyncEx",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "SwiftAsyncEx", targets: ["SwiftAsyncEx"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SwiftAsyncEx",
            dependencies: [],
            path: "Sources/SwiftAsyncEx"
        ),
        .testTarget(
            name: "SwiftAsyncExTests",
            dependencies: ["SwiftAsyncEx"],
            path: "Tests/SwiftAsyncExTests"
        ),
    ]
)
