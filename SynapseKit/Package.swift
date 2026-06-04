// swift-tools-version: 5.9
// Package.swift — SynapseKit
//
// A pure-Swift package with zero third-party dependencies.
// Only Foundation is used (for socket communication).
// Compatible with macOS 15+.

import PackageDescription

let package = Package(
    name: "SynapseKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SynapseKit",
            targets: ["SynapseKit"]
        ),
    ],
    targets: [
        .target(
            name: "SynapseKit",
            path: "Sources/SynapseKit"
        ),
        .testTarget(
            name: "SynapseKitTests",
            dependencies: ["SynapseKit"],
            path: "Tests/SynapseKitTests"
        ),
    ]
)
