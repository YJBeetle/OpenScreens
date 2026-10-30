// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenScreensCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "OpenScreensCore", targets: ["OpenScreensCore"]),
        .executable(name: "Probe", targets: ["Probe"]),
    ],
    targets: [
        .binaryTarget(name: "rfb_ffiFFI", path: "OpenScreensCore.xcframework"),
        .target(
            name: "OpenScreensCore",
            dependencies: ["rfb_ffiFFI"],
            path: "Sources/OpenScreensCore"
        ),
        .executableTarget(
            name: "Probe",
            dependencies: ["OpenScreensCore"],
            path: "Sources/Probe"
        ),
    ]
)
