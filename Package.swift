// swift-tools-version:5.9

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
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "SwiftToolsSupportCAS", package: "swift-tools-support-async"),
                .product(name: "Logging", package: "swift-log"),
                "AsyncProcess2",
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "Instrumentation", package: "swift-distributed-tracing"),
                .product(name: "_NIOFileSystem", package: "swift-nio")
            ]
        ),
        .testTarget(
            name: "llbuild2fxTests",
            dependencies: ["llbuild2fx"]
        ),

        // Async Process vendored library
        // TODO: global target name conflict shenanigans.
        .target(
            name: "AsyncProcess2",
            dependencies: [
                "ProcessSpawnSync2",
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Sources/AsyncProcess"
        ),
        .testTarget(
            name: "AsyncProcess2Tests",
            dependencies: [
                "AsyncProcess2",
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "_NIOFileSystem", package: "swift-nio"),
            ],
            path: "Tests/AsyncProcessTests"
        ),
        .target(
            name: "CProcessSpawnSync2",
            cSettings: [
                .define("_GNU_SOURCE")
            ]
        ),
        .target(
            name: "ProcessSpawnSync2",
            dependencies: [
                "CProcessSpawnSync2",
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            path: "Sources/ProcessSpawnSync"
        ),

        // Bazel RemoteAPI Protocol
        .target(
            name: "BazelRemoteAPI",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "SwiftProtobufPluginLibrary", package: "swift-protobuf"),
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
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftToolsSupportCAS", package: "swift-tools-support-async"),
            ]
        ),

        // llcastool implementation
        .target(
            name: "LLBCASTool",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftToolsSupport-auto", package: "swift-tools-support-core"),
                "BazelRemoteAPI",
                "LLBBazelBackend",
            ]
        ),

        // `llcastool` executable.
        .executableTarget(
            name: "llcastool",
            dependencies: ["LLBCASTool", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "Sources/Tools/llcastool"
        ),
    ]
)
