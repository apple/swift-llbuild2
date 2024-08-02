// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MemoizedWebCrawler",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-llbuild2.git", .upToNextMajor(from: "0.17.7")),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.1"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "MemoizedWebCrawler",
            dependencies: [
                .product(name: "llbuild2fx", package: "swift-llbuild2"),
                .product(name: "llbuild2Util", package: "swift-llbuild2"),
                .product(name: "AsyncHTTPClient", package: "async-http-client")
            ]
        ),
        .testTarget(name: "MemoizedWebCrawlerTests", dependencies: [
            .target(name: "MemoizedWebCrawler"),
        ])
    ]
)
