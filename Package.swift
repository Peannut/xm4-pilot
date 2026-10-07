// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XM4Pilot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "XM4Pilot",
            swiftSettings: [.define("MENU_BAR_APP")]
        ),
        .testTarget(
            name: "XM4PilotTests",
            dependencies: ["XM4Pilot"]
        ),
    ]
)
