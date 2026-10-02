// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Merry",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MerryCore", targets: ["MerryCore"]),
        .library(name: "MerryUI", targets: ["MerryUI"]),
        .executable(name: "Merry", targets: ["MerryApp"])
    ],
    targets: [
        // Everything that is not interface: the task loop, tools, model
        // clients, stores and the macOS adapter.
        .target(name: "MerryCore", path: "Sources/MerryCore"),
        // Windows, views and Merry's own WebKit browser.
        .target(name: "MerryUI", dependencies: ["MerryCore"], path: "Sources/MerryUI", resources: [.copy("Resources")]),
        .executableTarget(name: "MerryApp", dependencies: ["MerryCore", "MerryUI"], path: "Sources/MerryApp"),
        .testTarget(name: "MerryCoreTests", dependencies: ["MerryCore"], path: "Tests/MerryCoreTests"),
        .testTarget(name: "MerryUITests", dependencies: ["MerryCore", "MerryUI"], path: "Tests/MerryUITests")
    ],
    swiftLanguageModes: [.v5]
)
