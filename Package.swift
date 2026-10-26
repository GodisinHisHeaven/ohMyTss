// swift-tools-version: 5.9
import PackageDescription

// Compiles the exact framework-free source files also included in the iOS target.
let package = Package(
    name: "OhMyTssDomain",
    products: [.library(name: "OhMyTssDomain", targets: ["OhMyTssDomain"])],
    targets: [
        .target(name: "OhMyTssDomain", path: "onMyTss/onMyTss/Domain"),
        .testTarget(name: "DomainTests", dependencies: ["OhMyTssDomain"], path: "Tests/DomainTests")
    ]
)
