// swift-tools-version: 6.0
import PackageDescription

// The Max Pane app.
//
// Split into a library and a three-line executable so the app is testable at
// all: an `.executableTarget` cannot be imported by a test target, and the
// seams worth testing — the ledger wrapper, the `BROWSER` shim's protocol, the
// Relay spawn argv — are all in the library.
//
// Builds with SwiftPM alone; there is no Xcode on this machine. `build.sh`
// assembles the .app bundle and ad-hoc signs it, which is what WebKit needs
// before it will spawn content processes.
let package = Package(
    name: "MaxPane",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../MaxPaneCore"),
        // Ghostty's terminal core, as a prebuilt XCFramework. See ADR-0009 for
        // why this replaced SwiftTerm.
        // A fork, one commit ahead of upstream 1.6.20260909: the Ghostty
        // resource bundle is looked up in the app's Contents/Resources before
        // SwiftPM's Bundle.module, which only knows the app root (unsealable)
        // and this machine's build directory. build-app.sh copies the bundle
        // there. Rebase the branch `max-pane` when taking an upstream release.
        .package(url: "https://github.com/ddrscott/libghostty-spm.git", exact: "1.6.20260909-maxpane.1"),
    ],
    targets: [
        // zlib's gzip container. BUFFER_REPLAY_GZ (0x13) is a complete RFC 1952
        // gzip member — not raw deflate and not zlib — so Apple's Compression
        // framework cannot read it. `inflateInit2(&s, 16 + MAX_WBITS)` can.
        .target(name: "CRelayGzip", linkerSettings: [.linkedLibrary("z")]),

        // The RelayTTY protocol client, promoted from spike M2 where it was
        // measured byte-exact across 137 712 lines on 30 concurrent sessions.
        .target(name: "RelayClient", dependencies: ["CRelayGzip"], path: "Sources/RelayClient"),

        .target(
            name: "MaxPaneKit",
            dependencies: [
                .product(name: "LanedCore", package: "MaxPaneCore"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                "RelayClient",
            ],
            path: "Sources/MaxPaneKit"
        ),
        .executableTarget(
            name: "MaxPane",
            dependencies: ["MaxPaneKit"],
            path: "Sources/MaxPane"
        ),
        .testTarget(
            name: "MaxPaneKitTests",
            dependencies: ["MaxPaneKit", "RelayClient", .product(name: "LanedCore", package: "MaxPaneCore")],
            path: "Tests/MaxPaneKitTests"
        ),
    ]
)
