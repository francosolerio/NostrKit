// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NostrKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
        .tvOS(.v26),
        .watchOS(.v26),
        .macCatalyst(.v26)
    ],
    products: [
        .library(
            name: "NostrKit",
            targets: ["NostrKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SparrowTek/CoreNostr.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "NostrKit",
            dependencies: [
                "CoreNostr",
            ]),
        .testTarget(
            name: "NostrKitTests",
            dependencies: ["NostrKit"]
        ),
    ]
)
