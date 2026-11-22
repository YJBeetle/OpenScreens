// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScrctlGuiClient",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "ScrctlGuiClient", targets: ["ScrctlGuiClient"]),
        .executable(name: "ClientProbe", targets: ["ClientProbe"]),
    ],
    dependencies: [
        .package(path: "../ScrctlGuiUI"),
        .package(path: "../ScrctlGuiCore"),
    ],
    targets: [
        .target(
            name: "ScrctlGuiClient",
            dependencies: [
                .product(name: "ScrctlGuiUI", package: "ScrctlGuiUI"),
                .product(name: "ScrctlGuiCanvas", package: "ScrctlGuiUI"),
                .product(name: "ScrctlGuiCore", package: "ScrctlGuiCore"),
            ],
            path: "Sources/ScrctlGuiClient"
        ),
        .testTarget(name: "ScrctlGuiClientTests", dependencies: ["ScrctlGuiClient", "ScrctlGuiUI"]),
        .executableTarget(
            name: "ClientProbe",
            dependencies: ["ScrctlGuiClient", "ScrctlGuiUI"],
            path: "Sources/ClientProbe"
        ),
    ],
    swiftLanguageModes: [.v6]
)
