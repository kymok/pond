// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Pond",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TaskCore", targets: ["TaskCore"]),
        .executable(name: "Pond", targets: ["PondApp"]),
        .executable(name: "taskpond", targets: ["TaskCLI"])
    ],
    targets: [
        .target(name: "TaskCore"),
        .executableTarget(
            name: "PondApp",
            dependencies: ["TaskCore"]
        ),
        .executableTarget(
            name: "TaskCLI",
            dependencies: ["TaskCore"]
        ),
        .testTarget(
            name: "TaskCoreTests",
            dependencies: ["TaskCore"]
        )
    ]
)
