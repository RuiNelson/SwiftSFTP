#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<USAGE
Usage: ./Scripts/AndroidBuild/build.sh [swift build arguments...]

Cross-compile SwiftSFTP for Android. Run from the repository root.

Requires:
  - Swift 6.3+ with the Swift SDK for Android installed
  - ANDROID_NDK_HOME (NDK r27d+)

Environment:
  SWIFT_ANDROID_SDK   Target triple (default: aarch64-unknown-linux-android28)

Examples:
  ./Scripts/AndroidBuild/build.sh
  ./Scripts/AndroidBuild/build.sh test --scratch-path /tmp/swift-android-test --filter "Key Validation"
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ ! -f Package.swift ]]; then
    echo "Run this script from the repository root (expected Package.swift)." >&2
    exit 1
fi

# Prefer the swiftly toolchain; Xcode's Swift can mismatch the Android SDK Foundation module.
if [[ -x "$HOME/.swiftly/bin/swift" ]]; then
    export PATH="$HOME/.swiftly/bin:$PATH"
    swiftly use 6.3.2 >/dev/null 2>&1 || true
fi

SWIFT_ANDROID_SDK="${SWIFT_ANDROID_SDK:-aarch64-unknown-linux-android28}"
if [[ $# -eq 0 ]]; then
    set -- build --scratch-path /tmp/swift-android-build
fi

# --swift-sdk must follow the subcommand (build/test), not precede it.
swift "${@:1:1}" --swift-sdk "$SWIFT_ANDROID_SDK" "${@:2}"
