// swift-tools-version: 5.9
import PackageDescription

// RouteEngine depends only on Foundation (PLAN.md section 4) so it can be
// tested with `swift test` without a simulator or network.
let package = Package(
    name: "RouteEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RouteEngine", targets: ["RouteEngine"]),
    ],
    targets: [
        .target(name: "RouteEngine"),
        .testTarget(name: "RouteEngineTests", dependencies: ["RouteEngine"]),
    ]
)
