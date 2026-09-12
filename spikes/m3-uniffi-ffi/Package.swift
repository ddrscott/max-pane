// swift-tools-version: 6.0
import PackageDescription

// Spike M3: how long does a StripState round-trip across uniffi actually take?
let package = Package(
    name: "m3",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../swift/MaxPaneCore")],
    targets: [
        .executableTarget(
            name: "m3",
            dependencies: [.product(name: "LanedCore", package: "MaxPaneCore")],
            path: "Sources/m3"
        )
    ]
)
