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
        // Core build functionality
        .target(
            name: "llbuild2",
            dependencies: ["Crypto", "NIO", "SwiftToolsSupport-auto"]
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

        .target(
            name: "LLBUtil",
            dependencies: ["llbuild2", "CBLAKE3"]
        ),
        .testTarget(
            name: "LLBUtilTests",
            dependencies: ["LLBUtil"]
        ),

        .target(
            name: "LLBRETool",
            dependencies: [
                "GRPC",
                "SwiftToolsSupport-auto",
                "BazelRemoteAPI",
                "llbuild2",
                "LLBUtil",
            ]
        ),

        // Build system support
        .target(
            name: "LLBBuildSystem",
            dependencies: ["llbuild2", "LLBExecutionProtocol"]
        ),
        .target(
            name: "LLBExecutionProtocol",
            dependencies: ["llbuild2", "SwiftProtobuf"]
        ),
        .target(
            name: "LLBBuildSystemTestHelpers",
            dependencies: ["LLBBuildSystem"]
        ),
        .testTarget(
            name: "LLBBuildSystemTests",
            dependencies: ["LLBBuildSystemTestHelpers", "LLBUtil"]
        ),

        // Command line tools
        .target(
            name: "LLBCommands",
            dependencies: ["LLBNinja", "ArgumentParser"]
        ),

        // Executable multi-tool
        .target(
            name: "llbuild2-tool",
            dependencies: ["LLBCommands", "ArgumentParser"],
            path: "Sources/Tools/llbuild2-tool"
        ),

        // `retool` executable.
        .target(
            name: "retool",
            dependencies: ["LLBRETool", "ArgumentParser"],
            path: "Sources/Tools/retool"
        ),
    ]
)
