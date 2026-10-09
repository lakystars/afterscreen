// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AfterscreenSender",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AfterscreenSenderKit", targets: ["AfterscreenSenderKit"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "PrivateAPI", path: "Sources/PrivateAPI"),
        .target(name: "AfterscreenSenderKit",
                dependencies: ["PrivateAPI", .product(name: "AfterscreenCore", package: "Core")]),
        .executableTarget(name: "AfterscreenSender", dependencies: ["AfterscreenSenderKit"]),
        .testTarget(name: "AfterscreenSenderKitTests",
                    dependencies: ["AfterscreenSenderKit", .product(name: "AfterscreenCore", package: "Core")]),
    ]
)
