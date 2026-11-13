// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "EXIFKitConsumer",
    platforms: [.macOS(.v12), .iOS(.v15)],
    // The EXIFKit trait is disabled by default; without it, the SwiftSFTPEXIFKit module is empty.
    dependencies: [.package(name: "SwiftSFTP", path: "../../..", traits: ["EXIFKit"])],
    targets: [
        .testTarget(
            name: "EXIFKitConsumerTests",
            // EXIFKit comes through the product alone, re-exported by SwiftSFTPEXIFKit.
            dependencies: [.product(name: "SwiftSFTPEXIFKit", package: "SwiftSFTP")]
        ),
    ]
)
