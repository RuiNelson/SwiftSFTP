#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# Deliberately put foreign headers before all SwiftSFTP paths, as Xcode does.
xcrun --sdk macosx clang -fsyntax-only \
  -I"$ROOT/Tests/Packaging/CryptoIsolation/Sources/OtherCrypto/include" \
  -I"$ROOT/Sources/libssh2/include" \
  -I"$ROOT/vendor/libssh2/include" -I"$ROOT/vendor/libssh2/src" \
  -I"$ROOT/Sources/libssh2/apple" \
  -F"$ROOT/Artifacts/OpenSSL/OpenSSLCrypto.xcframework/macos-arm64" \
  -DHAVE_CONFIG_H -DLIBSSH2_OPENSSL -DHAVE_GETTIMEOFDAY -DHAVE_INTTYPES_H \
  -DHAVE_O_NONBLOCK -DHAVE_SELECT -DHAVE_SNPRINTF -DHAVE_SYS_SOCKET_H \
  -DHAVE_SYS_TIME_H -DHAVE_SYS_UIO_H -DHAVE_UNISTD_H \
  "$ROOT/vendor/libssh2/src/openssl.c"
echo "PASS: libssh2 ignores a foreign openssl/ tree earlier in the search path"
