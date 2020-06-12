// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GameOfLife",
    platforms: [
       .macOS(.v10_15)
    ],
    products: [
        .executable(
            name: "game_of_life",
            targets: ["GameOfLife"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "GameOfLife",
            dependencies: ["llbuild2BuildSystem", "llbuild2Util"]),
    ]
)
