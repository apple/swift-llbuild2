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
        .library(name: "llbuild2Util", targets: ["LLBUtil", "LLBBuildSystemUtil"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "0.0.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-llbuild.git", .branch("main")),
        .package(url: "https://github.com/apple/swift-tools-support-async.git", from: "0.1.0"),
        .package(url: "https://github.com/apple/swift-tools-support-core.git", from: "0.1.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.8.0"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.0.0-alpha.21"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.2.0"),
    ],
    targets: [
        // Core build functionality
        .target(
            name: "llbuild2",
            dependencies: ["SwiftToolsSupportCAS", "Logging"]
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
            dependencies: ["llbuild2"]
        ),
        .testTarget(
            name: "LLBUtilTests",
            dependencies: ["LLBUtil"]
        ),

        // Bazel CAS/Execution Backend
        .target(
            name: "LLBBazelBackend",
            dependencies: ["llbuild2", "BazelRemoteAPI", "Crypto", "GRPC"]
        ),

        // Build system support
        .target(
            name: "LLBBuildSystem",
            dependencies: ["llbuild2", "SwiftProtobuf", "Crypto"]
        ),
        .target(
            name: "LLBBuildSystemUtil",
            dependencies: ["llbuild2", "SwiftToolsSupport-auto", "LLBBuildSystem"]
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
