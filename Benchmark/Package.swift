// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SwiftSFTPBenchmark",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "swift-sftp-benchmark", targets: ["SwiftSFTPBenchmark"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(
            url: "https://github.com/orlandos-nl/Citadel.git",
            .upToNextMajor(from: "0.12.1")
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            .upToNextMajor(from: "1.8.2")
        ),
    ],
    targets: [
        .executableTarget(
            name: "SwiftSFTPBenchmark",
            dependencies: [
                .product(name: "SwiftSFTP", package: "SwiftSFTP"),
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
