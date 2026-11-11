// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChatKitExample",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        // A stupid-app project contains exactly one library product representing the application.
        .library(name: "ChatKitExample", targets: ["ChatKitExample"]),
    ],
    dependencies: [
        .package(name: "stupid-chatkit", path: "../.."),
    ],
    targets: [
        .target(name: "ChatKitExample", dependencies: [.product(name: "StupidChatKit", package: "stupid-chatkit")]),
    ],
)
