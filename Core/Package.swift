// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AfterscreenCore",
    platforms: [.macOS(.v10_15)],
    products: [.library(name: "AfterscreenCore", targets: ["AfterscreenCore"])],
    targets: [
        .target(name: "AfterscreenCore"),
        .testTarget(name: "AfterscreenCoreTests", dependencies: ["AfterscreenCore"]),
    ]
)
