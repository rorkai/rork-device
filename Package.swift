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
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMajor(from: "2.100.0")),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", .upToNextMajor(from: "2.37.1")),
    ],
    targets: [
        .target(
            name: "RorkDevice",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
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
            dependencies: [
                "RorkDevice",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            resources: [
                .process("Fixtures"),
            ]
        ),
        .testTarget(
            name: "RorkDeviceCLITests",
            dependencies: ["RorkDeviceCLI"]
        ),
    ]
)
