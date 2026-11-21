// swift-tools-version: 5.9
import PackageDescription

// Builds with the Command Line Tools (no Xcode needed). llama.cpp is linked statically from Vendor/llama,
// which scripts/build-llama.sh produces.
let vendor = "\(Context.packageDirectory)/Vendor/llama"

let package = Package(
    name: "Cedar",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CLlama", path: "Sources/CLlama"),
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
