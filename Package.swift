// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

// OpenSSL source manifest SHA-256: 3edb73fd5a871401d549c070019bbb3ac9316b530d70f3d3d47e1875c59debab

struct OpenSSLSourceManifest: Decodable {
    let sources: [String]
    let excluded: [String]
}

let opensslSources = try JSONDecoder().decode(
    OpenSSLSourceManifest.self,
    from: Data(contentsOf: URL(fileURLWithPath: Context.packageDirectory)
        .appendingPathComponent("Sources/OpenSSLCrypto/UPSTREAM.json"))
)

// Prepared from the pinned, unmodified OpenSSL submodule. SwiftPM compiles these
// portable C sources for the destination: no binary targets or build-time tools.
let opensslTarget = Target.target(
    name: "OpenSSLCrypto",
    exclude: ["LICENSE.txt", "UPSTREAM.json"] + opensslSources.excluded,
    sources: opensslSources.sources,
    publicHeadersPath: "include",
    cSettings: [
        .headerSearchPath("."),
        .headerSearchPath("private"),
        .headerSearchPath("crypto"),
        .headerSearchPath("crypto/modes"),
        .headerSearchPath("providers/common/include"),
        .headerSearchPath("providers/implementations/include"),
        .headerSearchPath("providers/fips/include"),
        .define("OPENSSL_BUILDING_OPENSSL"),
        .define("OPENSSLDIR", to: "\"\""),
        .define("MODULESDIR", to: "\"\""),
        .define("NDEBUG"),
        .define("_GNU_SOURCE", .when(platforms: [.linux, .android])),
        .define("OPENSSL_APPLE_CRYPTO_RANDOM", .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])),
    ],
    linkerSettings: [.linkedLibrary("pthread", .when(platforms: [.linux]))]
)

let libssh2ExcludedPaths = [
    // This target's root also contains other targets and their resources.
    "Sources/OpenSSLCrypto",
    "Sources/SwiftSFTP",
    "Tests",
    "Documentation",
    "Scripts",
    "TestServer",
    "vendor/openssl",
    "vendor/PathWorks",
    "vendor/libssh2/.github",
    "vendor/libssh2/cmake",
    "vendor/libssh2/docs",
    "vendor/libssh2/example",
    "vendor/libssh2/m4",
    "vendor/libssh2/os400",
    "vendor/libssh2/tests",
    "vendor/libssh2/vms",
    "vendor/libssh2/CMakeLists.txt",
    "vendor/libssh2/Makefile.am",
    "vendor/libssh2/REUSE.toml",
    "vendor/libssh2/appveyor.sh",
    "vendor/libssh2/configure.ac",
    "vendor/libssh2/libssh2.pc.in",
    "vendor/libssh2/src/Makefile.am",
    "vendor/libssh2/src/Makefile.inc",
    "vendor/libssh2/src/libssh2.rc",
    "vendor/libssh2/src/libssh2_config_cmake.h.in",
]

let libssh2Sources = [
    "Sources/libssh2/server_sign_algorithms.c",
    "Sources/libssh2/swiftsftp_bcrypt_pbkdf.c",
    "vendor/libssh2/src/agent.c",
    "vendor/libssh2/src/bcrypt_pbkdf.c",
    "vendor/libssh2/src/chacha.c",
    "vendor/libssh2/src/channel.c",
    "vendor/libssh2/src/cipher-chachapoly.c",
    "vendor/libssh2/src/comp.c",
    "vendor/libssh2/src/crypt.c",
    "vendor/libssh2/src/global.c",
    "vendor/libssh2/src/hostkey.c",
    "vendor/libssh2/src/keepalive.c",
    "vendor/libssh2/src/kex.c",
    "vendor/libssh2/src/knownhost.c",
    "vendor/libssh2/src/libgcrypt.c",
    "vendor/libssh2/src/mac.c",
    "vendor/libssh2/src/mbedtls.c",
    "vendor/libssh2/src/misc.c",
    "vendor/libssh2/src/openssl.c",
    "vendor/libssh2/src/os400qc3.c",
    "vendor/libssh2/src/packet.c",
    "vendor/libssh2/src/pem.c",
    "vendor/libssh2/src/poly1305.c",
    "vendor/libssh2/src/publickey.c",
    "vendor/libssh2/src/scp.c",
    "vendor/libssh2/src/session.c",
    "vendor/libssh2/src/sftp.c",
    "vendor/libssh2/src/transport.c",
    "vendor/libssh2/src/userauth.c",
    "vendor/libssh2/src/userauth_kbd_packet.c",
    "vendor/libssh2/src/version.c",
    "vendor/libssh2/src/wincng.c",
]

let libssh2CSettings: [CSetting] = [
    .headerSearchPath("vendor/libssh2/include"),
    .headerSearchPath("vendor/libssh2/src"),
    // Select our qualified backend before another SDK's openssl/ headers.
    .headerSearchPath("Sources/libssh2/openssl"),
    .define("HAVE_CONFIG_H"),
    .define("HAVE_GETTIMEOFDAY"),
    .define("HAVE_INTTYPES_H"),
    .define("HAVE_O_NONBLOCK"),
    .define("HAVE_SELECT"),
    .define("HAVE_SNPRINTF"),
    .define("HAVE_SYS_SOCKET_H"),
    .define("HAVE_SYS_TIME_H"),
    .define("HAVE_SYS_UIO_H"),
    .define("HAVE_UNISTD_H"),
    .define("LIBSSH2_OPENSSL"),
]

let libssh2Target = Target.target(
    name: "libssh2",
    dependencies: ["OpenSSLCrypto"],
    path: ".",
    exclude: libssh2ExcludedPaths,
    sources: libssh2Sources,
    publicHeadersPath: "Sources/libssh2/include",
    cSettings: libssh2CSettings
)

let strictConcurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let swiftSFTPTarget = Target.target(
    name: "SwiftSFTP",
    dependencies: ["libssh2", "OpenSSLCrypto"] + [
        .product(name: "PathWorks", package: "PathWorks"),
        .product(name: "Logging", package: "swift-log"),
    ],
    resources: [.copy("PrivacyInfo.xcprivacy")],
    swiftSettings: strictConcurrencySettings
)

let swiftSFTPTestsTarget = Target.testTarget(
    name: "SwiftSFTPTests",
    dependencies: ["SwiftSFTP", "libssh2", "OpenSSLCrypto"],
    swiftSettings: strictConcurrencySettings
)

let package = Package(
    name: "SwiftSFTP",
    platforms: [
        .macOS(.v11),
        .iOS(.v14),
        .visionOS(.v1),
        .watchOS(.v7),
        .tvOS(.v14),
        .custom("android", versionString: "28"),
    ],
    products: [
        .library(
            name: "SwiftSFTP",
            // OpenSSL is compiled into SwiftSFTP with SDK-private C symbols. Keeping
            // the product dynamic also maintains the existing delivery contract.
            type: .dynamic,
            targets: ["SwiftSFTP"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/RuiNelson/PathWorks.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [opensslTarget, libssh2Target, swiftSFTPTarget, swiftSFTPTestsTarget],
    swiftLanguageModes: [.v6]
)
