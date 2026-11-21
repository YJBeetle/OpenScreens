// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenScreensXdb",
    platforms: [.macOS(.v15)],
    products: [.library(name: "OpenScreensXdb", targets: ["OpenScreensXdb"])],
    targets: [
        .binaryTarget(name: "xdb_ffiFFI", path: "XdbCore.xcframework"),
        .target(name: "OpenScreensXdb", dependencies: ["xdb_ffiFFI"]),
    ]
)
