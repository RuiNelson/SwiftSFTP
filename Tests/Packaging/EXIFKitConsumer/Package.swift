// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "EXIFKitConsumer",
    platforms: [.macOS(.v12), .iOS(.v15)],
    dependencies: [.package(name: "SwiftSFTP", path: "../../..")],
    targets: [
        .testTarget(
            name: "EXIFKitConsumerTests",
            // EXIFKit comes through the product alone, re-exported by SwiftSFTPEXIFKit.
            dependencies: [.product(name: "SwiftSFTPEXIFKit", package: "SwiftSFTP")]
        ),
    ]
)
