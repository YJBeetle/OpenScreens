// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenScreensUI",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "OpenScreensUI", targets: ["OpenScreensUI"]),
        .library(name: "OpenScreensCanvas", targets: ["OpenScreensCanvas"])
    ],
    targets: [
        .target(
            name: "OpenScreensCanvas"
        ),
        .target(
            name: "OpenScreensUI",
            dependencies: ["OpenScreensCanvas"]
        ),
        .testTarget(
            name: "OpenScreensUITests",
            dependencies: ["OpenScreensUI"]
        )
    ],
    swiftLanguageModes: [.v6]
)
