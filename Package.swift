// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MaixKiosk",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MaixKiosk",
            path: "Sources/MaixKiosk"
        )
    ]
)
