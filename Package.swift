// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BWMonitor",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BWMonitorCore", targets: ["BWMonitorCore"])
    ],
    targets: [
        .target(
            name: "BWMonitorCore",
            path: "BWMonitorCore"
        ),
        .testTarget(
            name: "BWMonitorCoreTests",
            dependencies: ["BWMonitorCore"],
            path: "Tests/BWMonitorCoreTests"
        )
    ]
)
