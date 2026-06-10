#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENSSL_SOURCE_DIR="${OPENSSL_SOURCE_DIR:-"$ROOT_DIR/vendor/openssl"}"
OUTPUT_DIR="${OPENSSL_OUTPUT_DIR:-"$ROOT_DIR/Artifacts/OpenSSL/Android"}"
BUILD_DIR="${OPENSSL_BUILD_DIR:-"$ROOT_DIR/.openssl-android-build"}"
ANDROID_API="${ANDROID_API:-28}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--api N]

Build static OpenSSL libraries for Android ABIs used by SwiftSFTP.

Requires ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) pointing at NDK r27d+.

Options:
  --api N  Android API level (default: 28).
  -h, --help  Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api)
      ANDROID_API="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$OPENSSL_SOURCE_DIR/Configure" ]]; then
  echo "OpenSSL source not found at $OPENSSL_SOURCE_DIR" >&2
  echo "Run: git submodule update --init --recursive vendor/openssl" >&2
  exit 1
fi

NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "$NDK_HOME" || ! -d "$NDK_HOME" ]]; then
  echo "ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) must point at a valid Android NDK." >&2
  exit 1
fi
export ANDROID_NDK_ROOT="$NDK_HOME"

case "$(uname -s)" in
  Darwin)
    NDK_PREBUILT="darwin-x86_64"
    ;;
  Linux)
    NDK_PREBUILT="linux-x86_64"
    ;;
  *)
    echo "Unsupported host OS for this script: $(uname -s)" >&2
    exit 1
    ;;
esac

TOOLCHAIN_BIN="$NDK_HOME/toolchains/llvm/prebuilt/$NDK_PREBUILT/bin"
if [[ ! -d "$TOOLCHAIN_BIN" ]]; then
  echo "NDK toolchain not found at $TOOLCHAIN_BIN" >&2
  exit 1
fi

export PATH="$TOOLCHAIN_BIN:$PATH"

build_abi() {
  local abi="$1"
  local configure_target="$2"
  local clang_prefix="$3"
  local work_dir="$BUILD_DIR/src-$abi"
  local install_dir="$OUTPUT_DIR/lib/$abi"

  rm -rf "$work_dir"
  mkdir -p "$work_dir" "$install_dir"
  rsync -a --exclude .git "$OPENSSL_SOURCE_DIR/" "$work_dir/"

  (
    cd "$work_dir"
    export CC="${clang_prefix}${ANDROID_API}-clang"
    export AR="llvm-ar"
    export RANLIB="llvm-ranlib"
    perl Configure "$configure_target" \
      -D__ANDROID_API__="$ANDROID_API" \
      no-shared no-module no-tests no-apps no-docs \
      --prefix="$install_dir"
    make -j"$JOBS"
    make install_sw
  )
}

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR/include" "$OUTPUT_DIR/lib"

build_abi "arm64-v8a" "android-arm64" "aarch64-linux-android"
build_abi "x86_64" "android-x86_64" "x86_64-linux-android"

rsync -a --delete "$OUTPUT_DIR/lib/arm64-v8a/include/" "$OUTPUT_DIR/include/"

echo "Built static OpenSSL for Android in $OUTPUT_DIR"
echo "ABIs: arm64-v8a, x86_64 (API $ANDROID_API)"
