// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EQForMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EQForMac",
            path: "Sources/EQForMac",
            exclude: ["Info.plist"],
            resources: [
                .copy("Resources/headphones"),
                .copy("Resources/autoeq"),
                .copy("Resources/headphones_catalog.json"),
                .copy("Resources/graph_names.txt"),
                .copy("Resources/target_curves.json"),
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/EQForMac/Info.plist",
                ]),
            ]
        )
    ]
)
