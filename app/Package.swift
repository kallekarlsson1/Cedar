// swift-tools-version: 5.9
import PackageDescription

// Cedar: the search panel and its engine in one binary. Plain AppKit, so it builds with the Command Line Tools
// alone (no Xcode). llama.cpp is linked statically from Vendor/llama (scripts/build-llama.sh builds it).
let vendor = "\(Context.packageDirectory)/Vendor/llama"

let package = Package(
    name: "Cedar",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CLlama", path: "Sources/CLlama"),
        // The engine: reading documents, the indexes, search, the model. No UI.
        .target(
            name: "CedarKit",
            dependencies: ["CLlama"],
            path: "Sources/CedarKit",
            cSettings: [.unsafeFlags(["-I\(vendor)/include"])],
            swiftSettings: [.unsafeFlags(["-I\(vendor)/include", "-Xcc", "-I\(vendor)/include"])],
            linkerSettings: [
                .unsafeFlags(["-L\(vendor)/lib"]),
                .linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"), .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(name: "Cedar", dependencies: ["CedarKit"], path: "Sources/Cedar"),
    ]
)
