// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SwiftSFTPBenchmark",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "swift-sftp-benchmark", targets: ["SwiftSFTPBenchmark"]),
        .executable(name: "swift-sftp-multitune", targets: ["SwiftSFTPMultiTune"]),
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
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
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
        .executableTarget(
            name: "SwiftSFTPMultiTune",
            dependencies: [
                .product(name: "SwiftSFTP", package: "SwiftSFTP"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
