// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClaudeWidget",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "ClaudeWidget",
            path: "ClaudeWidget",
            exclude: ["Info.plist"]
        )
    ]
)
