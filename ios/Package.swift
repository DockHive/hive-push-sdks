// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HivePush",
    platforms: [
        .iOS(.v14),
        // macOS is supported so the package and its tests build on a Mac host;
        // push registration helpers are iOS-only.
        .macOS(.v11),
    ],
    products: [
        .library(name: "HivePush", targets: ["HivePush"]),
    ],
    targets: [
        .target(name: "HivePush"),
        .testTarget(name: "HivePushTests", dependencies: ["HivePush"]),
    ]
)
