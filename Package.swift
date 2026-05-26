// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SmolTodo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TodoCore", targets: ["TodoCore"]),
        .executable(name: "SmolTodo", targets: ["SmolTodoApp"]),
        .executable(name: "todo", targets: ["TodoCLI"])
    ],
    targets: [
        .target(name: "TodoCore"),
        .executableTarget(
            name: "SmolTodoApp",
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
