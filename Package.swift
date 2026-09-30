// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Barista",
    platforms: [.macOS(.v13)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Barista",
            dependencies: [],
            path: "Barista",
            exclude: ["Info.plist", "Info-Marketbar.plist", "Barista.entitlements"],
            resources: [.copy("Web")],
            linkerSettings: [
                .linkedFramework("CoreWLAN")
            ]
        ),
        .testTarget(
            name: "BaristaTests",
            dependencies: ["Barista"],
            path: "Tests/BaristaTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
