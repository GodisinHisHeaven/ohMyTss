// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SharedUI",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "SharedUI",
            targets: ["SharedUI"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SharedUI",
            dependencies: []
        ),
    ]
)
