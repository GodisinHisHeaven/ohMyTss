// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HealthStore",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "HealthStore",
            targets: ["HealthStore"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "HealthStore",
            dependencies: []
        ),
        .testTarget(
            name: "HealthStoreTests",
            dependencies: ["HealthStore"]
        ),
    ]
)
