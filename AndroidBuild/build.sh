#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<USAGE
Usage: ./AndroidBuild/build.sh [swift build arguments...]

Cross-compile SwiftSFTP for Android. Run from the repository root.

Requires:
  - Swift 6.3+ with the Swift SDK for Android installed
  - ANDROID_NDK_HOME (NDK r27d+)
  - OpenSSL Android artifacts (run ./Scripts/build-openssl-android.sh first)

Environment:
  SWIFT_ANDROID_SDK   Target triple (default: aarch64-unknown-linux-android28)
  ANDROID_ABI         OpenSSL ABI folder (default: arm64-v8a)

Examples:
  ./AndroidBuild/build.sh
  ./AndroidBuild/build.sh test --scratch-path /tmp/swift-android-test --filter "Key Validation"
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ ! -d .git ]]; then
    echo "Run this script from the repository root (expected a .git directory)." >&2
    exit 1
fi

ROOT="$(pwd)"
SWIFT_ANDROID_SDK="${SWIFT_ANDROID_SDK:-aarch64-unknown-linux-android28}"
ANDROID_ABI="${ANDROID_ABI:-arm64-v8a}"
OPENSSL_LIB_DIR="$ROOT/Artifacts/OpenSSL/Android/lib/$ANDROID_ABI/lib"
OPENSSL_INCLUDE_DIR="$ROOT/Artifacts/OpenSSL/Android/include"

if [[ ! -f "$OPENSSL_LIB_DIR/libcrypto.a" || ! -f "$OPENSSL_LIB_DIR/libssl.a" ]]; then
    echo "OpenSSL Android artifacts not found for ABI '$ANDROID_ABI'." >&2
    echo "Run ./Scripts/build-openssl-android.sh first." >&2
    exit 1
fi

export LDFLAGS="-L$OPENSSL_LIB_DIR ${LDFLAGS:-}"
export CPPFLAGS="-I$OPENSSL_INCLUDE_DIR ${CPPFLAGS:-}"
export CFLAGS="${CPPFLAGS} ${CFLAGS:-}"

if [[ $# -eq 0 ]]; then
    set -- build --scratch-path /tmp/swift-android-build
fi

swift "$@" --swift-sdk "$SWIFT_ANDROID_SDK"
