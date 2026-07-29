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
    .headerSearchPath("Artifacts/OpenSSL/Android/include", .when(platforms: [.android])),
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
    path: ".",
    exclude: libssh2ExcludedPaths,
    sources: libssh2Sources,
    publicHeadersPath: "Sources/libssh2/include",
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
