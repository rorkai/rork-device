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
        .package(
            url: "https://github.com/apple/swift-certificates.git",
            "1.10.0"..<"1.11.0"
        ),
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            "3.12.5"..<"3.13.0"
        ),
        .package(url: "https://github.com/attaswift/BigInt.git", .upToNextMajor(from: "5.7.0")),
    ],
    targets: [
        .target(
            name: "RorkDeviceLwIP",
            path: "Sources/RorkDeviceLwIP",
            exclude: [
                "Vendor/lwip/COPYING",
            ],
            sources: [
                "RorkDeviceLwIP.c",
                "Vendor/lwip/src/core/init.c",
                "Vendor/lwip/src/core/def.c",
                "Vendor/lwip/src/core/inet_chksum.c",
                "Vendor/lwip/src/core/ip.c",
                "Vendor/lwip/src/core/mem.c",
                "Vendor/lwip/src/core/memp.c",
                "Vendor/lwip/src/core/netif.c",
                "Vendor/lwip/src/core/pbuf.c",
                "Vendor/lwip/src/core/stats.c",
                "Vendor/lwip/src/core/sys.c",
                "Vendor/lwip/src/core/tcp.c",
                "Vendor/lwip/src/core/tcp_in.c",
                "Vendor/lwip/src/core/tcp_out.c",
                "Vendor/lwip/src/core/timeouts.c",
                "Vendor/lwip/src/core/ipv6/icmp6.c",
                "Vendor/lwip/src/core/ipv6/inet6.c",
                "Vendor/lwip/src/core/ipv6/ip6.c",
                "Vendor/lwip/src/core/ipv6/ip6_addr.c",
                "Vendor/lwip/src/core/ipv6/nd6.c",
                "Vendor/lwip/src/netif/ethernet.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("Configuration"),
                .headerSearchPath("Vendor/lwip/src/include"),
            ]
        ),
        .target(
            name: "RorkDevice",
            dependencies: [
                "RorkDeviceLwIP",
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
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
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
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
