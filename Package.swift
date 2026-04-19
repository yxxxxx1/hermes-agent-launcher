// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "HermesMacLauncherApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "HermesMacLauncherApp",
            targets: ["HermesMacLauncherApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "HermesMacLauncherApp",
            path: "macos-app/Sources"
        )
    ]
)
