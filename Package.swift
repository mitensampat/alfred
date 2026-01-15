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
        ),
        .executable(
            name: "alfred-app",
            targets: ["AlfredApp"]
        )
    ],
    dependencies: [
        // No external dependencies needed - using Foundation and URLSession
    ],
    targets: [
        .executableTarget(
            name: "Alfred",
            dependencies: [],
            path: "Sources",
            exclude: ["GUI"]
        ),
        .executableTarget(
            name: "AlfredApp",
            dependencies: [],
            path: "Sources/GUI"
        ),
        .testTarget(
            name: "AlfredTests",
            dependencies: ["Alfred"],
            path: "Tests"
        )
    ]
)
