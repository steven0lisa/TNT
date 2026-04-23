// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TNT",
    platforms: [.macOS("13.0")],
    products: [
        .executable(name: "TNT", targets: ["TNT"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "TNT",
            dependencies: [],
            path: "Sources"
        )
    ]
)
