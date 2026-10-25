// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "cduyzhMenuBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "cduyzhMenuBar", targets: ["MenuBarApp"])],
    dependencies: [],
    targets: [
        .target(name: "MenuBarCore", path: "Sources/MenuBarCore"),
        .executableTarget(name: "MenuBarApp", dependencies: ["MenuBarCore"], path: "Sources/MenuBarApp"),
        .testTarget(name: "MenuBarCoreTests", dependencies: ["MenuBarCore"], path: "Tests/MenuBarCoreTests")
    ]
)
