// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlankCanvas",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BlankCanvas", targets: ["BlankCanvas"]),
    ],
    targets: [
        .executableTarget(name: "BlankCanvas", path: "Sources/BlankCanvas"),
        .testTarget(
            name: "BlankCanvasTests",
            dependencies: ["BlankCanvas"],
            path: "Tests/BlankCanvasTests",
            exclude: ["Fixtures"]
        ),
    ]
)
