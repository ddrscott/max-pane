// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "m2-relay-attach",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RelayClient", targets: ["RelayClient"]),
        .executable(name: "m2bench", targets: ["m2bench"]),
        .executable(name: "M2Harness", targets: ["M2Harness"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
    ],
    targets: [
        .target(
            name: "CRelayGzip",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(name: "RelayClient", dependencies: ["CRelayGzip"]),
        .executableTarget(
            name: "m2bench",
            dependencies: ["RelayClient", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .executableTarget(
            name: "M2Harness",
            dependencies: ["RelayClient", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
    ]
)
