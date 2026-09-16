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
                // gen-bindings.sh puts the static archive, and nothing else,
                // in lib/. Do not point this at target/: cargo leaves a .dylib
                // beside the .a there, ld picks the .dylib, and the app ends up
                // loading the core from the repo by absolute path at runtime.
                // Absolute, because ld resolves -L against whichever directory
                // `swift build` was run from, not the package root.
                .unsafeFlags(["-L", "\(Context.packageDirectory)/lib"]),
                .linkedLibrary("laned_core"),
            ]
        ),
        .target(name: "LanedCore", dependencies: ["laned_coreFFI"], path: "Sources/LanedCore"),
    ]
)
