// swift-tools-version: 5.9
import PackageDescription

// The search panel. Plain AppKit, so it builds with the Command Line Tools alone (no Xcode).
let package = Package(
    name: "Cedar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Cedar", path: "Sources/Cedar"),
    ]
)
