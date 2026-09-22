// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MEGACoexistence",
    platforms: [.iOS("27.0")],
    dependencies: [.package(name: "SwiftSFTP", path: "../../..")],
    targets: [
        // URL and checksum from meganz/iOS Modules/DataSource/MEGASDK/Package.swift.
        .binaryTarget(
            name: "libmega",
            url: "https://s3.g.s4.mega.io/dmlaaezwz52y37atz56mfvmrvltfagrltbgpr/ios-xcframeworks/libmega_25_12_12.xcframework.zip",
            checksum: "f1e94204bf47c79f65733bc5e9b9606857448a1645c88a59d106c643fac38b92"
        ),
        .target(name: "MEGACrypto", dependencies: ["libmega"]),
        .testTarget(
            name: "MEGACoexistenceTests",
            dependencies: ["MEGACrypto", .product(name: "SwiftSFTP", package: "SwiftSFTP")]
        ),
    ]
)
