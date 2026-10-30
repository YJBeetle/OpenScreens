// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenScreensClient",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "OpenScreensClient", targets: ["OpenScreensClient"]),
        .executable(name: "ClientProbe", targets: ["ClientProbe"]),
    ],
    dependencies: [
        .package(path: "../OpenScreensUI"),
        .package(path: "../OpenScreensCore"),
    ],
    targets: [
        .target(
            name: "OpenScreensClient",
            dependencies: [
                .product(name: "OpenScreensUI", package: "OpenScreensUI"),
                .product(name: "OpenScreensCanvas", package: "OpenScreensUI"),
                .product(name: "OpenScreensCore", package: "OpenScreensCore"),
            ],
            path: "Sources/OpenScreensClient"
        ),
        .executableTarget(
            name: "ClientProbe",
            dependencies: ["OpenScreensClient", "OpenScreensUI"],
            path: "Sources/ClientProbe"
        ),
    ],
    swiftLanguageModes: [.v6]
)
