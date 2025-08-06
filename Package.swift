// swift-tools-version:5.1

import PackageDescription

let package = Package(
    name: "llbuild2",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .library(name: "llbuild2", targets: ["llbuild2"]),
        .library(name: "llbuild2fx", targets: ["llbuild2fx"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.0.4"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.1.4"..<"4.0.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing", from: "1.1.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.4.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.17.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.1.1"),
        .package(url: "https://github.com/apple/swift-tools-support-async.git", from: "0.10.0"),
        .package(url: "https://github.com/apple/swift-tools-support-core.git", from: "0.2.7"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.4.1"),
    ],
    targets: [
        // FX build engine
        .target(
            name: "llbuild2fx",
            dependencies: [
                "SwiftProtobuf",
                "SwiftToolsSupportCAS",
                "Logging",
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "Instrumentation", package: "swift-distributed-tracing"),
            ]
        ),
        .testTarget(
            name: "llbuild2fxTests",
            dependencies: ["llbuild2fx"]
        ),

        // Async Process vendored library
        .target(
            name: "AsyncProcess",
            dependencies: [
                "ProcessSpawnSync",
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
        .testTarget(
            name: "AsyncProcessTests",
            dependencies: [
                "AsyncProcess",
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "_NIOFileSystem", package: "swift-nio"),
            ]
        ),
        .target(
            name: "CProcessSpawnSync",
            cSettings: [
                .define("_GNU_SOURCE")
            ]
        ),
        .target(
            name: "ProcessSpawnSync",
            dependencies: [
                "CProcessSpawnSync",
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ]
        ),

        // Bazel RemoteAPI Protocol
        .target(
            name: "BazelRemoteAPI",
            dependencies: [
                "GRPC",
                "SwiftProtobuf",
                "SwiftProtobufPluginLibrary",
            ]
        ),

        // Compatibility/convenience wrapper library
        .target(
            name: "llbuild2",
            dependencies: ["llbuild2fx"]
        ),

        // Bazel CAS/Execution Backend
        .target(
            name: "LLBBazelBackend",
            dependencies: [
                "BazelRemoteAPI",
                "Crypto",
                "GRPC",
                "SwiftToolsSupportCAS",
            ]
        ),

        // llcastool implementation
        .target(
            name: "LLBCASTool",
            dependencies: [
                "GRPC",
                "SwiftToolsSupport-auto",
                "BazelRemoteAPI",
                "LLBBazelBackend",
            ]
        ),

        // `llcastool` executable.
        .target(
            name: "llcastool",
            dependencies: ["LLBCASTool", "ArgumentParser"],
            path: "Sources/Tools/llcastool"
        ),
    ]
)
