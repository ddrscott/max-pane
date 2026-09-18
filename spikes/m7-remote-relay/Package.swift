// swift-tools-version: 5.9
import PackageDescription

// Spike M7: one remote relay-tty session through relaytty.com, measured.
// RelayClient and CRelayGzip are symlinks into swift/MaxPane/Sources, so the
// transport under measurement is the one the app links, not a copy.
let package = Package(
    name: "m7-remote-relay",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CRelayGzip", path: "Sources/CRelayGzip", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "RelayClient", dependencies: ["CRelayGzip"], path: "Sources/RelayClient"),
        .target(name: "CProcInfo", path: "Sources/CProcInfo"),
        .executableTarget(name: "m7", dependencies: ["RelayClient", "CProcInfo"], path: "Sources/m7"),
    ]
)
