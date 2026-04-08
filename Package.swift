// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "llbuild2",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "llbuild2", targets: ["llbuild2"]),
        .library(name: "llbuild2fx", targets: ["llbuild2fx"]),
        .library(name: "llbuild2Testing", targets: ["llbuild2Testing"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.0.4"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing", from: "1.1.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.4.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.17.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.1.1"),
        .package(url: "https://github.com/apple/swift-tools-support-async.git", from: "0.17.0"),
        .package(url: "https://github.com/apple/swift-tools-support-core.git", from: "0.2.7"),
    ],
    targets: [
        // Vendored BLAKE3 C implementation
        .target(
            name: "FXCBLAKE3",
            dependencies: [],
            exclude: ["impl", "LICENSE"],
            cSettings: [
                .headerSearchPath("./")
            ]
        ),

        // Vendored process spawn sync C implementation
        .target(
            name: "FXCProcessSpawnSync",
            dependencies: [],
            cSettings: [
                .define("_GNU_SOURCE")
            ]
        ),

        // FXCore: public client-facing types (CAS protocols, data types, NIO typealiases)
        .target(
            name: "FXCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
            ]
        ),

        // FXAsyncSupport: package-scoped internals (file trees, process executor, futures utilities)
        .target(
            name: "FXAsyncSupport",
            dependencies: [
                "FXCore",
                "FXCBLAKE3",
                "FXCProcessSpawnSync",
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ]
        ),

        // FX build engine
        .target(
            name: "llbuild2fx",
            dependencies: [
                "FXCore",
                "FXAsyncSupport",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "Instrumentation", package: "swift-distributed-tracing"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "_NIOFileSystem", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "llbuild2fxTests",
            dependencies: ["llbuild2fx", "llbuild2Testing"]
        ),
        .testTarget(
            name: "FXCoreTests",
            dependencies: ["FXCore", "FXAsyncSupport"]
        ),
        .testTarget(
            name: "FXAsyncSupportTests",
            dependencies: [
                "FXAsyncSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ]
        ),
        .testTarget(
            name: "llbuild2TestingTests",
            dependencies: ["llbuild2Testing", "FXAsyncSupport"]
        ),
        .testTarget(
            name: "FXExampleRulesetTests",
            dependencies: ["FXExampleRuleset", "llbuild2Testing"]
        ),

        // Example ruleset (not part of the library — for testing and reference only)
        .target(
            name: "FXExampleRuleset",
            dependencies: ["llbuild2fx"]
        ),

        // Testing support module
        .target(
            name: "llbuild2Testing",
            dependencies: [
                "llbuild2fx",
                "FXAsyncSupport",
            ]
        ),

        // Compatibility/convenience wrapper library
        .target(
            name: "llbuild2",
            dependencies: ["llbuild2fx"]
        ),

        // Interop test: verifies TSFCAS types can bridge to FXCASDatabase
        .testTarget(
            name: "FXInteropTests",
            dependencies: [
                "llbuild2fx",
                "llbuild2Testing",
                .product(name: "SwiftToolsSupportCAS", package: "swift-tools-support-async"),
            ]
        ),
    ]
)
