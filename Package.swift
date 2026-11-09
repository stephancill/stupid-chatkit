// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "StupidChatKit",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(name: "StupidChatKit", targets: ["StupidChatKit"]),
    ],
    targets: [
        // Chat models, view models, storage and UI; knows no network.
        .target(
            name: "StupidChatKit",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "StupidChatKitTests",
            dependencies: ["StupidChatKit"]
        ),
    ]
)
