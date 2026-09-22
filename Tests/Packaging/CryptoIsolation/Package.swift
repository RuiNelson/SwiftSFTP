// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "CryptoIsolation",
    platforms: [.macOS(.v11), .iOS(.v14)],
    dependencies: [.package(name: "SwiftSFTP", path: "../../..")],
    targets: [
        .target(name: "OtherCrypto"),
        .testTarget(
            name: "CryptoIsolationTests",
            dependencies: ["OtherCrypto", .product(name: "SwiftSFTP", package: "SwiftSFTP")]
        ),
    ]
)
