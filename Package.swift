// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PortWizard",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "PortWizard",
            path: "Sources/PortWizard",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "PortWizardTests",
            dependencies: ["PortWizard"],
            path: "Tests/PortWizardTests"
        )
    ]
)
