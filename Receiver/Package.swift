// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AfterscreenReceiver",
    platforms: [.macOS(.v10_15)],
    products: [.library(name: "AfterscreenReceiverKit", targets: ["AfterscreenReceiverKit"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "AfterscreenReceiverKit", dependencies: [.product(name: "AfterscreenCore", package: "Core")]),
        .executableTarget(name: "AfterscreenReceiver", dependencies: ["AfterscreenReceiverKit"]),
        .testTarget(name: "AfterscreenReceiverKitTests",
                    dependencies: ["AfterscreenReceiverKit", .product(name: "AfterscreenCore", package: "Core")]),
    ]
)
