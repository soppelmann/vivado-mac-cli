// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "vivado-mac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "vivado-mac",
            path: "Sources/vivado-mac",
            linkerSettings: [.linkedFramework("Virtualization")]
        )
    ]
)
