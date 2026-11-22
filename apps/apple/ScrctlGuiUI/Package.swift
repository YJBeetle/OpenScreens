// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScrctlGuiUI",
    platforms: [
        .iOS(.v17),
        .macOS(.v15)
    ],
    products: [
        .library(name: "ScrctlGuiUI", targets: ["ScrctlGuiUI"]),
        .library(name: "ScrctlGuiCanvas", targets: ["ScrctlGuiCanvas"])
    ],
    dependencies: [
        .package(path: "../ScrctlGuiCore"),
    ],
    targets: [
        .target(
            name: "ScrctlGuiCanvas"
        ),
        .target(
            name: "ScrctlGuiUI",
            dependencies: [
                "ScrctlGuiCanvas",
                .product(name: "ScrctlGuiCore", package: "ScrctlGuiCore"),
            ]
        ),
        .testTarget(
            name: "ScrctlGuiUITests",
            dependencies: ["ScrctlGuiUI"]
        )
    ],
    swiftLanguageModes: [.v6]
)
