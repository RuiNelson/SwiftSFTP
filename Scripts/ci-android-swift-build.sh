#!/usr/bin/env bash
# CI entry point for Android cross-compiles via swiftlang/github-workflows.
# The workflow appends `--swift-sdk <triple>` to this script's arguments.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ANDROID_ABI="${ANDROID_ABI:-arm64-v8a}"
./Scripts/build-openssl-android.sh --abi "$ANDROID_ABI"

OPENSSL_LIB_DIR="$ROOT/Artifacts/OpenSSL/Android/lib/$ANDROID_ABI/lib"
OPENSSL_INCLUDE_DIR="$ROOT/Artifacts/OpenSSL/Android/include"

export LDFLAGS="-L$OPENSSL_LIB_DIR ${LDFLAGS:-}"
export CPPFLAGS="-I$OPENSSL_INCLUDE_DIR ${CPPFLAGS:-}"
export CFLAGS="${CPPFLAGS} ${CFLAGS:-}"
export C_INCLUDE_PATH="$OPENSSL_INCLUDE_DIR${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
export CPLUS_INCLUDE_PATH="$OPENSSL_INCLUDE_DIR${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"

# SwiftPM ignores LDFLAGS; the OpenSSL search path has to reach the linker
# explicitly, otherwise linking libSwiftSFTP.so fails to find -lssl/-lcrypto.
#
# --exclude-libs hides the OpenSSL symbols inside libSwiftSFTP.so. Without it the
# static archives' internal symbols stay preemptible in a shared object and the
# aarch64 asm modules fail with "relocation ... cannot be used against symbol".
exec swift "$@" \
  -Xswiftc -L"$OPENSSL_LIB_DIR" \
  -Xlinker -L"$OPENSSL_LIB_DIR" \
  -Xlinker --exclude-libs=libcrypto.a \
  -Xlinker --exclude-libs=libssl.a
