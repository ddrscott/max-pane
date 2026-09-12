// swift-tools-version: 6.0
import PackageDescription

// The Max Pane app.
//
// Builds with SwiftPM alone — there is no Xcode on this machine. `build.sh`
// assembles the .app bundle around the executable and ad-hoc signs it, which is
// what WebKit needs before it will spawn content processes.
let package = Package(
    name: "MaxPane",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../MaxPaneCore"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "MaxPane",
            dependencies: [
                .product(name: "LanedCore", package: "MaxPaneCore"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/MaxPane"
        )
    ]
)
