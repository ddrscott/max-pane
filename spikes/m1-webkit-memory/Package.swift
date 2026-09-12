// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "M1Spike",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CProcInfo"),
        .executableTarget(
            name: "M1Spike",
            dependencies: ["CProcInfo"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
