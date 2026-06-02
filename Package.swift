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
            name: "RorkDevice",
            path: ".",
            exclude: [
                ".DS_Store",
                ".gitignore",
                ".swiftpm",
                ".vscode",
                "Artifacts",
                "Docs",
                "LICENSE",
                "Package.resolved",
                "Package.swift",
                "README.md",
                "Sources/RorkDeviceCLI",
                "Tests",
            ],
            sources: [
                "Sources/RorkDevice",
            ],
            resources: [
                .process("VERSION"),
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
            dependencies: ["RorkDevice"],
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
