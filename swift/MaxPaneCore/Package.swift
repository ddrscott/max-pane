// swift-tools-version: 6.0
import PackageDescription

// The Rust core, as a Swift module.
//
// `laned-core` is built by scripts/gen-bindings.sh into a static library; this
// package links it and exposes the uniffi-generated API as `LanedCore`. There
// is no Xcode on this machine, so this is a plain SwiftPM package rather than
// an XCFramework — `swift build` is the whole toolchain.
let package = Package(
    name: "MaxPaneCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LanedCore", targets: ["LanedCore"]),
    ],
    targets: [
        // The C ABI uniffi generated for the Rust side.
        .target(
            name: "laned_coreFFI",
            path: "Sources/laned_coreFFI",
            publicHeadersPath: "include",
            linkerSettings: [
                // Resolved relative to the package root; ../../../target is the
                // cargo workspace's output directory.
                .unsafeFlags(["-L", "../../target/release"]),
                .linkedLibrary("laned_core"),
            ]
        ),
        .target(name: "LanedCore", dependencies: ["laned_coreFFI"], path: "Sources/LanedCore"),
    ]
)
