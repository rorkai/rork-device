// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "rork-device",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "RorkDevice",
            targets: ["RorkDevice"]
        ),
        .executable(
            name: "rorkdevice",
            targets: ["RorkDeviceCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", .upToNextMajor(from: "1.5.0")),
    ],
    targets: [
        .target(
            name: "RorkDevice"
        ),
        .executableTarget(
            name: "RorkDeviceCLI",
            dependencies: [
                "RorkDevice",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "RorkDeviceTests",
            dependencies: ["RorkDevice"]
        ),
        .testTarget(
            name: "RorkDeviceCLITests",
            dependencies: ["RorkDeviceCLI"]
        ),
    ]
)
