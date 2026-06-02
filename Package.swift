// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftSFTP",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .visionOS(.v2),
        .watchOS(.v11),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SwiftSFTP",
            targets: ["SwiftSFTP"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "OpenSSLCrypto",
            path: "Artifacts/OpenSSL/OpenSSLCrypto.xcframework"
        ),
        .binaryTarget(
            name: "OpenSSLSSL",
            path: "Artifacts/OpenSSL/OpenSSLSSL.xcframework"
        ),
        .target(
            name: "libssh2",
            dependencies: ["OpenSSLCrypto"],
            path: "vendor/libssh2",
            exclude: [
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
            ],
            sources: [
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
            ],
            publicHeadersPath: "include",
            cSettings: [
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
        ),
        .target(
            name: "SwiftSFTP",
            dependencies: ["libssh2", "OpenSSLCrypto"]
        ),
        .testTarget(
            name: "SwiftSFTPTests",
            dependencies: ["SwiftSFTP", "libssh2", "OpenSSLCrypto"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
