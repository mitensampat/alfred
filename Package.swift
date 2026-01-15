// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Alfred",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "alfred",
            targets: ["Alfred"]
        )
    ],
    dependencies: [
        // No external dependencies needed - using Foundation and URLSession
    ],
    targets: [
        .executableTarget(
            name: "Alfred",
            dependencies: [],
            path: "Sources"
        ),
        .testTarget(
            name: "AlfredTests",
            dependencies: ["Alfred"],
            path: "Tests"
        )
    ]
)
