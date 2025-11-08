// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TSSEngine",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "TSSEngine",
            targets: ["TSSEngine"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TSSEngine",
            dependencies: []
        ),
        .testTarget(
            name: "TSSEngineTests",
            dependencies: ["TSSEngine"]
        ),
    ]
)
