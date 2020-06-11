// swift-tools-version:5.1

import PackageDescription

let package = Package(
    name: "llbuild2",
    platforms: [
       .macOS(.v10_15)
    ],
    products: [
        .library(name: "llbuild2", targets: ["llbuild2"]),
        .library(name: "llbuild2Ninja", targets: ["LLBNinja"]),
        .library(name: "llbuild2BuildSystem", targets: ["LLBBuildSystem"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "0.0.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-llbuild.git", .branch("master")),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.8.0"),
        .package(url: "https://github.com/apple/swift-tools-support-core.git", .branch("master")),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.8.0"),
        .package(url: "https://github.com/grpc/grpc-swift.git", .branch("master")),
    ],
    targets: [
        // ZSTD Compression support
        .target(name: "CZSTD"),
        .target(name: "ZSTD", dependencies: ["CZSTD"]),
        .testTarget(name: "ZSTDTests", dependencies: ["ZSTD"]),

        // Support types and methods
        .target(
            name: "LLBSupport",
            dependencies: ["NIO", "SwiftToolsSupport-auto", "ZSTD"]
        ),
        .testTarget(
            name: "LLBSupportTests",
            dependencies: ["LLBSupport"]
        ),

        // CAS Protocol
        .target(
            name: "LLBCAS",
            dependencies: ["LLBSupport", "SwiftProtobuf"]
        ),
        .testTarget(
            name: "LLBCASTests",
            dependencies: ["LLBCAS", "LLBUtil"]
        ),
        .target(
            name: "LLBCASFileTree",
            dependencies: ["LLBCAS", "ZSTD"]
        ),
        .testTarget(
            name: "LLBCASFileTreeTests",
            dependencies: ["LLBCASFileTree", "LLBUtil"]
        ),

        // Core build functionality
        .target(
            name: "llbuild2",
            dependencies: ["LLBCASFileTree", "Crypto"]
        ),
        .testTarget(
            name: "llbuild2Tests",
            dependencies: ["llbuild2", "LLBUtil"]
        ),

        // Bazel RemoteAPI Protocol
        .target(
            name: "BazelRemoteAPI",
            dependencies: ["GRPC", "SwiftProtobuf", "SwiftProtobufPluginLibrary"]
        ),

        // BLAKE3 hash support
        .target(
            name: "CBLAKE3",
            dependencies: [],
            cSettings: [
                .headerSearchPath("./"),
            ]
        ),

        // Ninja Build support
        .target(
            name: "LLBNinja",
            dependencies: ["llbuild2", "LLBUtil", "Ninja"]
        ),
        .testTarget(
            name: "LLBNinjaTests",
            dependencies: ["LLBNinja", "SwiftToolsSupport-auto"]
        ),

        // Utility classes, including concrete/default implementations of core
        // protocols that clients and/or tests may find useful.
        .target(
            name: "LLBUtil",
            dependencies: ["llbuild2", "LLBCAS", "CBLAKE3"]
        ),
        .testTarget(
            name: "LLBUtilTests",
            dependencies: ["LLBUtil"]
        ),

        // Bazel CAS/Execution Backend
        .target(
            name: "LLBBazelBackend",
            dependencies: ["llbuild2", "BazelRemoteAPI", "GRPC"]
        ),

        // Build system support
        .target(
            name: "LLBBuildSystem",
            dependencies: ["llbuild2", "LLBBuildSystemProtocol", "SwiftProtobuf", "Crypto"]
        ),
        .target(
            name: "LLBBuildSystemProtocol",
            dependencies: ["llbuild2", "LLBCAS", "SwiftProtobuf"]
        ),
        .target(
            name: "LLBBuildSystemUtil",
            dependencies: ["LLBBuildSystemProtocol", "SwiftToolsSupport-auto", "LLBCASFileTree"]
        ),
        .target(
            name: "LLBBuildSystemTestHelpers",
            dependencies: ["LLBBuildSystem", "LLBUtil"]
        ),
        .testTarget(
            name: "LLBBuildSystemTests",
            dependencies: ["LLBBuildSystemTestHelpers", "LLBUtil", "LLBBuildSystemUtil"]
        ),
        .testTarget(
            name: "LLBBuildSystemUtilTests",
            dependencies: ["LLBBuildSystemUtil", "LLBBuildSystemTestHelpers", "LLBUtil"]
        ),

        // Command line tools
        .target(
            name: "LLBCommands",
            dependencies: ["LLBNinja", "ArgumentParser"]
        ),

        // llcastool implementation
        .target(
            name: "LLBCASTool",
            dependencies: [
                "GRPC",
                "SwiftToolsSupport-auto",
                "BazelRemoteAPI",
                "llbuild2",
                "LLBBazelBackend",
                "LLBUtil",
            ]
        ),


        // Executable multi-tool
        .target(
            name: "llbuild2-tool",
            dependencies: ["LLBCommands", "ArgumentParser"],
            path: "Sources/Tools/llbuild2-tool"
        ),

        // `llcastool` executable.
        .target(
            name: "llcastool",
            dependencies: ["LLBCASTool", "ArgumentParser"],
            path: "Sources/Tools/llcastool"
        ),
    ]
)
