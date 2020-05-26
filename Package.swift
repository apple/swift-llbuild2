// swift-tools-version:5.1

import PackageDescription

let package = Package(
    name: "llbuild2",
    platforms: [
       .macOS(.v10_15) 
    ],
    products: [
        .library(name: "llbuild2", targets: ["llbuild2"]),
        .library(name: "llbuild2Ninja", targets: ["llbuild2Ninja"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "0.0.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-llbuild.git", .branch("master")),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.8.0"),
        .package(url: "https://github.com/apple/swift-tools-support-core.git", from: "0.0.1"),
    ],
    targets: [
        // Core build functionality
        .target(
            name: "llbuild2",
            dependencies: ["Crypto", "NIO"]
        ),
        .testTarget(
            name: "llbuild2Tests",
            dependencies: ["llbuild2", "llbuild2Util"]
        ),

        // Ninja Build support
        .target(
            name: "llbuild2Ninja",
            dependencies: ["llbuild2", "llbuild2Util", "Ninja"]
        ),
        .testTarget(
            name: "llbuild2NinjaTests",
            dependencies: ["llbuild2Ninja", "SwiftToolsSupport-auto"]
        ),

        .target(
            name: "llbuild2Util",
            dependencies: ["llbuild2"]
        ),


        // Command line tools
        .target(
            name: "llbuild2Commands",
            dependencies: ["llbuild2Ninja", "ArgumentParser"]
        ),

        // Executable multi-tool
        .target(
            name: "llbuild2-tool",
            dependencies: ["llbuild2Commands", "ArgumentParser"],
            path: "Sources/Tools/llbuild2-tool"
        ),
    ]
)
