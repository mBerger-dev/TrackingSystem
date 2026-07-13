// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SensorCore",
    products: [
        .library(name: "SensorCore", targets: ["SensorCore"]),
    ],
    targets: [
        .target(name: "SensorCore"),
        .testTarget(name: "SensorCoreTests", dependencies: ["SensorCore"]),
    ]
)
