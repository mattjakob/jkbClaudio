// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Claudio",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Claudio",
            path: "Claudio",
            exclude: ["Info.plist", "Claudio.entitlements"],
            resources: [.process("Resources")]
        )
    ]
)
