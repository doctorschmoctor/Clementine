// swift-tools-version:5.10
// Clementine Tools: the native file tool windows Filee opens from the donut (see src/Filee.App/Services/ToolLauncher.cs).
import PackageDescription

let package = Package(
    name: "ClementineTools",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClementineTools", path: "Sources/ClementineTools")
    ]
)
