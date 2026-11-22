// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScrctlGuiXdb",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ScrctlGuiXdb", targets: ["ScrctlGuiXdb"])],
    targets: [
        .binaryTarget(name: "xdb_ffiFFI", path: "XdbCore.xcframework"),
        .target(name: "ScrctlGuiXdb", dependencies: ["xdb_ffiFFI"]),
    ]
)
