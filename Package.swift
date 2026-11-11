// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "VerticalStudio",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "VerticalStudio", targets: ["VerticalStudio"])],
    targets: [
        .target(name: "VerticalCore"),
        .executableTarget(name: "VerticalStudio", dependencies: ["VerticalCore"]),
        .executableTarget(name: "CoreValidation", dependencies: ["VerticalCore"], path: "Tests/VerticalCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
