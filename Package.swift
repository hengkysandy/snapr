// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnaprCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SnaprCore", targets: ["SnaprCore"])
    ],
    targets: [
        // No AppKit, no ScreenCaptureKit, no Vision. Deliberately.
        //
        // Every decision this app makes must be answerable without a display,
        // a permission or a running app, so the core tests run in a fraction of
        // a second with no simulator. The measured reason this matters: the
        // FTS5 sanitizer has to survive 29 hostile inputs and not one of them
        // needs a screen.
        //
        // SQLCipher is NOT here. Only the app target uses it, and adding it
        // would force the core tests to carry a database they do not need.
        .target(name: "SnaprCore"),
        .testTarget(name: "SnaprCoreTests", dependencies: ["SnaprCore"]),
    ]
)
