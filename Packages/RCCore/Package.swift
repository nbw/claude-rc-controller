// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RCCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "RCCore", targets: ["RCCore"])],
    targets: [
        .target(name: "RCCore"),
        .testTarget(
            name: "RCCoreTests",
            dependencies: ["RCCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
