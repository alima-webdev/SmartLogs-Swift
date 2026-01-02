// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SmartLogs",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .tvOS(.v26)
    ],
    products: [
        .library(
            name: "SmartLogs",
            targets: ["SmartLogs"]
        ),
    ],
    targets: [
        .target(name: "SmartLogs"),
    ]
)
