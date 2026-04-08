// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "wallpaperd",
    platforms: [
        .macOS(.v14)  // Sonoma+, for modern AVPlayer and screen APIs
    ],
    targets: [
        .executableTarget(
            name: "wallpaperd",
            path: "Sources/WallpaperDaemon",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        )
    ]
)
