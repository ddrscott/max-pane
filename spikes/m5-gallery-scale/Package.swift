// swift-tools-version: 6.0
import PackageDescription

// Spike M5: can a lane be drawn as a gallery thumbnail without resizing
// anything, and does it stay sharp and cheap? See README.md and
// docs/spikes/05-gallery-scale.md.
//
// Pinned to the exact libghostty-spm the app resolves, so the numbers are about
// the renderer the app actually ships.
let package = Package(
    name: "GalleryScale",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.6.20260909"),
    ],
    targets: [
        .executableTarget(
            name: "GalleryScale",
            dependencies: [.product(name: "GhosttyTerminal", package: "libghostty-spm")],
            path: "Sources/GalleryScale",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
