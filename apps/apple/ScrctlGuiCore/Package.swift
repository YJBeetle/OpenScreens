// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScrctlGuiCore",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "ScrctlGuiCore", targets: ["ScrctlGuiCore"]),
        .executable(name: "Probe", targets: ["Probe"]),
    ],
    targets: [
        .binaryTarget(name: "rfb_ffiFFI", path: "ScrctlGuiCore.xcframework"),
        .target(
            name: "ScrctlGuiCore",
            dependencies: ["rfb_ffiFFI"],
            path: "Sources/ScrctlGuiCore"
        ),
        .executableTarget(
            name: "Probe",
            dependencies: ["ScrctlGuiCore"],
            path: "Sources/Probe"
        ),
    ]
)
