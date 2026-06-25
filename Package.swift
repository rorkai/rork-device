// swift-tools-version: 6.0

import PackageDescription

let nativePlatforms: [Platform] = [
    .macOS,
    .macCatalyst,
    .iOS,
    .tvOS,
    .watchOS,
    .visionOS,
    .linux,
    .windows,
    .android,
    .openbsd,
]

var products: [Product] = [
    .library(
        name: "RorkDevice",
        targets: ["RorkDevice"]
    ),
    .executable(
        name: "rorkdevice",
        targets: ["RorkDeviceCLI"]
    ),
]

// Swift 6.3 selects the WASI-capable forks used by RorkDeviceWeb. Earlier
// toolchains retain the native package's Swift 6.0 compatibility by resolving
// the last upstream releases whose manifests support that toolchain.
#if compiler(>=6.3)
let swiftNIO: Package.Dependency = .package(
    url: "https://github.com/rorkai/swift-nio.git",
    exact: "2.100.0-rork.1"
)
let swiftNIOSSL: Package.Dependency = .package(
    url: "https://github.com/rorkai/swift-nio-ssl.git",
    exact: "2.37.1-rork.1"
)
#else
let swiftNIO: Package.Dependency = .package(
    url: "https://github.com/apple/swift-nio.git",
    "2.97.1"..<"2.98.0"
)
let swiftNIOSSL: Package.Dependency = .package(
    url: "https://github.com/apple/swift-nio-ssl.git",
    "2.36.1"..<"2.37.0"
)
#endif

// Swift 6.3 selects coordinated WASI forks. The Certificates fork resolves the
// same Crypto revision directly, which keeps the combined web package graph
// free of duplicate swift-crypto identities. Earlier toolchains retain upstream
// requirements and resolve the newest native releases their manifests support.
#if compiler(>=6.3)
let swiftCertificates: Package.Dependency = .package(
    url: "https://github.com/rorkai/swift-certificates.git",
    exact: "1.19.1-rork.1"
)
let swiftCrypto: Package.Dependency = .package(
    url: "https://github.com/rorkai/swift-crypto.git",
    exact: "4.5.0-rork.1"
)
#elseif compiler(>=6.1)
let swiftCertificates: Package.Dependency = .package(
    url: "https://github.com/apple/swift-certificates.git",
    from: "1.17.0"
)
let swiftCrypto: Package.Dependency = .package(
    url: "https://github.com/apple/swift-crypto.git",
    from: "4.0.0"
)
#else
let swiftCertificates: Package.Dependency = .package(
    url: "https://github.com/apple/swift-certificates.git",
    "1.17.0"..<"1.19.0"
)
let swiftCrypto: Package.Dependency = .package(
    url: "https://github.com/apple/swift-crypto.git",
    "4.0.0"..<"4.4.0"
)
#endif

let swiftArgumentParser: Package.Dependency = .package(
    url: "https://github.com/apple/swift-argument-parser.git",
    .upToNextMajor(from: "1.5.0")
)
let bigInt: Package.Dependency = .package(
    url: "https://github.com/attaswift/BigInt.git",
    .upToNextMajor(from: "5.7.0")
)
let swiftZipArchive: Package.Dependency = .package(
    url: "https://github.com/rorkai/swift-zip-archive.git",
    revision: "7c9b3255e92428cd8cdcfd817fea4d08271e4844"
)

var dependencies: [Package.Dependency] = [
    swiftArgumentParser,
    swiftNIO,
    swiftNIOSSL,
    swiftCertificates,
    swiftCrypto,
    bigInt,
    swiftZipArchive,
]

var targets: [Target] = [
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
            .target(
                name: "RorkDeviceLwIP",
                condition: .when(platforms: nativePlatforms)
            ),
            .product(
                name: "BigInt",
                package: "BigInt",
                condition: .when(platforms: nativePlatforms)
            ),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "NIOFoundationCompat", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(
                name: "X509",
                package: "swift-certificates",
                condition: .when(platforms: nativePlatforms)
            ),
            .product(
                name: "CryptoExtras",
                package: "swift-crypto",
                condition: .when(platforms: nativePlatforms)
            ),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "ZipArchive", package: "swift-zip-archive"),
        ]
    ),
    .executableTarget(
        name: "RorkDeviceCLI",
        dependencies: [
            "RorkDevice",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]
    ),
    .testTarget(
        name: "RorkDeviceTests",
        dependencies: [
            "RorkDevice",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "CryptoExtras", package: "swift-crypto"),
            .product(name: "ZipArchive", package: "swift-zip-archive"),
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

#if compiler(>=6.3)
products.append(
    .library(
        name: "RorkDeviceWeb",
        targets: ["RorkDeviceWeb"]
    )
)
dependencies.append(
    .package(
        url: "https://github.com/swiftwasm/JavaScriptKit.git",
        .upToNextMinor(from: "0.55.0")
    )
)
targets.append(
    .target(
        name: "RorkDeviceWeb",
        dependencies: [
            "RorkDevice",
            .product(
                name: "JavaScriptKit",
                package: "JavaScriptKit",
                condition: .when(platforms: [.wasi])
            ),
            .product(
                name: "JavaScriptEventLoop",
                package: "JavaScriptKit",
                condition: .when(platforms: [.wasi])
            ),
            .product(
                name: "JavaScriptFoundationCompat",
                package: "JavaScriptKit",
                condition: .when(platforms: [.wasi])
            ),
        ]
    )
)
targets.append(
    .testTarget(
        name: "RorkDeviceWebTests",
        dependencies: [
            "RorkDeviceWeb",
            .product(name: "CryptoExtras", package: "swift-crypto"),
            .product(name: "X509", package: "swift-certificates"),
        ]
    )
)
#endif

let package = Package(
    name: "rork-device",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v6]
)
