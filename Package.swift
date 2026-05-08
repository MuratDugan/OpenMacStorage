// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenMacStorage",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenMacStorage", targets: ["OpenMacStorage"])
    ],
    targets: [
        .executableTarget(
            name: "OpenMacStorage",
            path: "Sources/OpenMacStorage",
            resources: [.process("Resources")],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .unsafeFlags(["-O"], .when(configuration: .release))
            ]
        )
    ]
)
