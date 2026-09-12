// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StripBench",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StripBench",
            path: "Sources/StripBench",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
