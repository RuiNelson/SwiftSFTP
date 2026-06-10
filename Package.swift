// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let applePlatforms: [Platform] = [.macOS, .iOS, .tvOS, .watchOS, .visionOS]

let opensslTargets: [Target] = [
    .systemLibrary(
        name: "COpenSSL",
        path: "Sources/OpenSSL",
        providers: [
            .apt(["libssl-dev"]),
            .yum(["openssl-devel"]),
        ]
    ),
    .binaryTarget(
        name: "OpenSSLCrypto",
        path: "Artifacts/OpenSSL/OpenSSLCrypto.xcframework"
    ),
    .binaryTarget(
        name: "OpenSSLSSL",
        path: "Artifacts/OpenSSL/OpenSSLSSL.xcframework"
    ),
]

let libssh2OpenSSLDependencies: [Target.Dependency] = [
    .target(name: "COpenSSL", condition: .when(platforms: [.linux, .android])),
    .target(name: "OpenSSLCrypto", condition: .when(platforms: applePlatforms)),
]

let swiftSFTPOpenSSLDependencies: [Target.Dependency] = [
    .target(name: "COpenSSL", condition: .when(platforms: [.linux, .android])),
    .target(name: "OpenSSLCrypto", condition: .when(platforms: applePlatforms)),
]

let opensslLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("ssl", .when(platforms: [.linux, .android])),
    .linkedLibrary("crypto", .when(platforms: [.linux, .android])),
]

let libssh2ExcludedPaths = [
    ".github",
    "cmake",
    "docs",
    "example",
    "m4",
    "os400",
    "tests",
    "vms",
    "CMakeLists.txt",
    "Makefile.am",
    "REUSE.toml",
    "appveyor.sh",
    "configure.ac",
    "libssh2.pc.in",
    "src/Makefile.am",
    "src/Makefile.inc",
    "src/libssh2.rc",
    "src/libssh2_config_cmake.h.in",
]

let libssh2Sources = [
    "src/agent.c",
    "src/bcrypt_pbkdf.c",
    "src/chacha.c",
    "src/channel.c",
    "src/cipher-chachapoly.c",
    "src/comp.c",
    "src/crypt.c",
    "src/global.c",
    "src/hostkey.c",
    "src/keepalive.c",
    "src/kex.c",
    "src/knownhost.c",
    "src/libgcrypt.c",
    "src/mac.c",
    "src/mbedtls.c",
    "src/misc.c",
    "src/openssl.c",
    "src/os400qc3.c",
    "src/packet.c",
    "src/pem.c",
    "src/poly1305.c",
    "src/publickey.c",
    "src/scp.c",
    "src/session.c",
    "src/sftp.c",
    "src/transport.c",
    "src/userauth.c",
    "src/userauth_kbd_packet.c",
    "src/version.c",
    "src/wincng.c",
]

let libssh2CSettings: [CSetting] = [
    .headerSearchPath("src"),
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
    dependencies: libssh2OpenSSLDependencies,
    path: "vendor/libssh2",
    exclude: libssh2ExcludedPaths,
    sources: libssh2Sources,
    publicHeadersPath: "include",
    cSettings: libssh2CSettings,
    linkerSettings: opensslLinkerSettings
)

let swiftSFTPTarget = Target.target(
    name: "SwiftSFTP",
    dependencies: ["libssh2"] + swiftSFTPOpenSSLDependencies + [
        .product(name: "PathWorks", package: "PathWorks"),
        .product(name: "Logging", package: "swift-log"),
    ]
)

let swiftSFTPTestsTarget = Target.testTarget(
    name: "SwiftSFTPTests",
    dependencies: ["SwiftSFTP", "libssh2"] + swiftSFTPOpenSSLDependencies
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
            targets: ["SwiftSFTP"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/RuiNelson/PathWorks.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: opensslTargets + [libssh2Target, swiftSFTPTarget, swiftSFTPTestsTarget],
    swiftLanguageModes: [.v6]
)
