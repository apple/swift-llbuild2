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
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "0.0.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-llbuild.git", .branch("master")),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.8.0"),
        .package(url: "https://github.com/apple/swift-tools-support-core.git", from: "0.0.1"),
        .package(url: "https://github.com/apple/swift-protobuf.git", .branch("master")),
    ],
    targets: [
        // Core build functionality
        .target(
            name: "llbuild2",
            dependencies: ["Crypto", "NIO"]
        ),
        .testTarget(
            name: "llbuild2Tests",
            dependencies: ["llbuild2", "LLBUtil"]
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
            dependencies: ["llbuild2"]
        ),

        // Build system support
        .target(
            name: "LLBExecutionProtocol",
            dependencies: ["llbuild2", "SwiftProtobuf"]
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
    ]
)
