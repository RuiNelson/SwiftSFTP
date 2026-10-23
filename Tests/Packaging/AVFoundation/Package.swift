// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "AVFoundationConsumer",
    platforms: [.macOS(.v11), .iOS(.v14)],
    dependencies: [.package(name: "SwiftSFTP", path: "../../..")],
    targets: [
        .testTarget(
            name: "AVFoundationConsumerTests",
            dependencies: [.product(name: "SwiftSFTPAVFoundation", package: "SwiftSFTP")]
        ),
    ]
)
