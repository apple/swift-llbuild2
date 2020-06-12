// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "conway",
    platforms: [
       .macOS(.v10_15)
    ],
    products: [
        .executable(
            name: "conway",
            targets: ["Conway"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "Conway",
            dependencies: ["llbuild2BuildSystem", "llbuild2Util"]),
    ]
)
