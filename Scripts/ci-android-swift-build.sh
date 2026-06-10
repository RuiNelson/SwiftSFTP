#!/usr/bin/env bash
# CI entry point for Android cross-compiles via swiftlang/github-workflows.
# The workflow appends `--swift-sdk <triple>` to this script's arguments.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

./Scripts/build-openssl-android.sh

ANDROID_ABI="${ANDROID_ABI:-arm64-v8a}"
OPENSSL_LIB_DIR="$ROOT/Artifacts/OpenSSL/Android/lib/$ANDROID_ABI/lib"
OPENSSL_INCLUDE_DIR="$ROOT/Artifacts/OpenSSL/Android/include"

export LDFLAGS="-L$OPENSSL_LIB_DIR ${LDFLAGS:-}"
export CPPFLAGS="-I$OPENSSL_INCLUDE_DIR ${CPPFLAGS:-}"
export CFLAGS="${CPPFLAGS} ${CFLAGS:-}"
export C_INCLUDE_PATH="$OPENSSL_INCLUDE_DIR${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
export CPLUS_INCLUDE_PATH="$OPENSSL_INCLUDE_DIR${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"

exec swift "$@"
