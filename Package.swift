// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YTDownloader",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "YTDownloader",
            path: "Sources/YTDownloader",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVKit")
            ]
        )
    ]
)
