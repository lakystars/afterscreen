// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AfterscreenBench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../Core"), .package(path: "../Sender"), .package(path: "../Receiver")],
    targets: [
        .executableTarget(name: "AfterscreenBench", dependencies: [
            .product(name: "AfterscreenCore", package: "Core"),
            .product(name: "AfterscreenSenderKit", package: "Sender"),
            .product(name: "AfterscreenReceiverKit", package: "Receiver"),
        ]),
        .executableTarget(name: "AfterscreenPidstat"),
    ]
)
