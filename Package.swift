// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Pond",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TodoCore", targets: ["TodoCore"]),
        .executable(name: "Pond", targets: ["PondApp"]),
        .executable(name: "taskpond", targets: ["TodoCLI"])
    ],
    targets: [
        .target(name: "TodoCore"),
        .executableTarget(
            name: "PondApp",
            dependencies: ["TodoCore"]
        ),
        .executableTarget(
            name: "TodoCLI",
            dependencies: ["TodoCore"]
        ),
        .testTarget(
            name: "TodoCoreTests",
            dependencies: ["TodoCore"]
        )
    ]
)
