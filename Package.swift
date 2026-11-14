// swift-tools-version:5.9
// Lets Xcode / SwiftPM add this repository by URL. The package itself lives in ios/
// (open ios/Package.swift to work on it and run its tests).
import PackageDescription

let package = Package(
    name: "HivePush",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [
        .library(name: "HivePush", targets: ["HivePush"]),
    ],
    targets: [
        .target(name: "HivePush", path: "ios/Sources/HivePush"),
    ]
)
