#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENSSL_SOURCE_DIR="${OPENSSL_SOURCE_DIR:-"$ROOT_DIR/vendor/openssl"}"
OUTPUT_DIR="${OPENSSL_OUTPUT_DIR:-"$ROOT_DIR/Artifacts/OpenSSL"}"
BUILD_DIR="${OPENSSL_BUILD_DIR:-"$ROOT_DIR/.openssl-build"}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
BUILD_INTEL_MAC=0
BUILD_INTEL_SIM=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--intelMac] [--intelSim]

Build static OpenSSL XCFrameworks for SwiftPM.

Options:
  --intelMac  Include x86_64 macOS.
  --intelSim  Include x86_64 simulator slices.
  -h, --help  Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --intelMac)
      BUILD_INTEL_MAC=1
      ;;
    --intelSim)
      BUILD_INTEL_SIM=1
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
  shift
done

if [[ ! -f "$OPENSSL_SOURCE_DIR/Configure" ]]; then
  echo "OpenSSL source not found at $OPENSSL_SOURCE_DIR" >&2
  echo "Run: git submodule update --init --recursive vendor/openssl" >&2
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/OpenSSLCrypto.xcframework" "$OUTPUT_DIR/OpenSSLSSL.xcframework"

build_one() {
  local name="$1"
  local target="$2"
  local min_version_flag="$3"
  local work_dir="$BUILD_DIR/src-$name"
  local install_dir="$BUILD_DIR/install-$name"

  rsync -a --delete --exclude .git "$OPENSSL_SOURCE_DIR/" "$work_dir/"
  (
    cd "$work_dir"
    perl Configure "$target" no-shared no-module no-tests no-apps no-docs "$min_version_flag" --prefix="$install_dir"
    make -j"$JOBS"
    make install_sw
  )
}

build_generic_one() {
  local name="$1"
  local sdk="$2"
  local arch="$3"
  local target="$4"
  local min_version_flag="$5"
  local work_dir="$BUILD_DIR/src-$name"
  local install_dir="$BUILD_DIR/install-$name"
  local cflags="-arch $arch"

  if [[ -n "$min_version_flag" ]]; then
    cflags="$cflags $min_version_flag"
  fi

  rsync -a --delete --exclude .git "$OPENSSL_SOURCE_DIR/" "$work_dir/"
  (
    cd "$work_dir"
    CC="xcrun -sdk $sdk cc" CFLAGS="$cflags" perl Configure \
      "$target" no-asm no-shared no-tests no-apps no-docs \
      no-module \
      --prefix="$install_dir"
    make -j"$JOBS"
    make install_sw
  )
}

make_library_slice() {
  local output_dir="$1"
  local library_name="$2"
  shift 2
  local inputs=("$@")

  if [[ "${#inputs[@]}" -eq 1 ]]; then
    cp "${inputs[0]}" "$output_dir/lib/$library_name"
  else
    lipo -create "${inputs[@]}" -output "$output_dir/lib/$library_name"
  fi
}

build_one macos-arm64 darwin64-arm64-cc -mmacosx-version-min=15.0
if [[ "$BUILD_INTEL_MAC" -eq 1 ]]; then
  build_one macos-x86_64 darwin64-x86_64-cc -mmacosx-version-min=15.0
fi
build_one iphoneos-arm64 ios64-xcrun -miphoneos-version-min=18.0
build_one iphonesimulator-arm64 iossimulator-arm64-xcrun -mios-simulator-version-min=18.0
if [[ "$BUILD_INTEL_SIM" -eq 1 ]]; then
  build_one iphonesimulator-x86_64 iossimulator-x86_64-xcrun -mios-simulator-version-min=18.0
fi
build_generic_one xros-arm64 xros arm64 BSD-generic64 ""
build_generic_one xrsimulator-arm64 xrsimulator arm64 BSD-generic64 ""
if [[ "$BUILD_INTEL_SIM" -eq 1 ]]; then
  build_generic_one xrsimulator-x86_64 xrsimulator x86_64 BSD-generic64 ""
fi
build_generic_one watchos-arm64_32 watchos arm64_32 BSD-generic32 -mwatchos-version-min=11.0
build_generic_one watchos-arm64 watchos arm64 BSD-generic64 -mwatchos-version-min=11.0
build_generic_one watchsimulator-arm64 watchsimulator arm64 BSD-generic64 -mwatchos-simulator-version-min=11.0
if [[ "$BUILD_INTEL_SIM" -eq 1 ]]; then
  build_generic_one watchsimulator-x86_64 watchsimulator x86_64 BSD-generic64 -mwatchos-simulator-version-min=11.0
fi

MACOS_DIR="$BUILD_DIR/install-macos-universal"
IOS_SIM_DIR="$BUILD_DIR/install-iphonesimulator-universal"
XROS_SIM_DIR="$BUILD_DIR/install-xrsimulator-universal"
WATCHOS_DIR="$BUILD_DIR/install-watchos-universal"
WATCH_SIM_DIR="$BUILD_DIR/install-watchsimulator-universal"
mkdir -p "$MACOS_DIR/lib" "$IOS_SIM_DIR/lib" "$XROS_SIM_DIR/lib" "$WATCHOS_DIR/lib" "$WATCH_SIM_DIR/lib"
rsync -a "$BUILD_DIR/install-macos-arm64/include" "$MACOS_DIR/"
rsync -a "$BUILD_DIR/install-iphonesimulator-arm64/include" "$IOS_SIM_DIR/"
rsync -a "$BUILD_DIR/install-xrsimulator-arm64/include" "$XROS_SIM_DIR/"
rsync -a "$BUILD_DIR/install-watchos-arm64_32/include" "$WATCHOS_DIR/"
rsync -a "$BUILD_DIR/install-watchsimulator-arm64/include" "$WATCH_SIM_DIR/"

MACOS_CRYPTO=("$BUILD_DIR/install-macos-arm64/lib/libcrypto.a")
MACOS_SSL=("$BUILD_DIR/install-macos-arm64/lib/libssl.a")
IOS_SIM_CRYPTO=("$BUILD_DIR/install-iphonesimulator-arm64/lib/libcrypto.a")
IOS_SIM_SSL=("$BUILD_DIR/install-iphonesimulator-arm64/lib/libssl.a")
XROS_SIM_CRYPTO=("$BUILD_DIR/install-xrsimulator-arm64/lib/libcrypto.a")
XROS_SIM_SSL=("$BUILD_DIR/install-xrsimulator-arm64/lib/libssl.a")
WATCH_SIM_CRYPTO=("$BUILD_DIR/install-watchsimulator-arm64/lib/libcrypto.a")
WATCH_SIM_SSL=("$BUILD_DIR/install-watchsimulator-arm64/lib/libssl.a")

if [[ "$BUILD_INTEL_MAC" -eq 1 ]]; then
  MACOS_CRYPTO+=("$BUILD_DIR/install-macos-x86_64/lib/libcrypto.a")
  MACOS_SSL+=("$BUILD_DIR/install-macos-x86_64/lib/libssl.a")
fi

if [[ "$BUILD_INTEL_SIM" -eq 1 ]]; then
  IOS_SIM_CRYPTO+=("$BUILD_DIR/install-iphonesimulator-x86_64/lib/libcrypto.a")
  IOS_SIM_SSL+=("$BUILD_DIR/install-iphonesimulator-x86_64/lib/libssl.a")
  XROS_SIM_CRYPTO+=("$BUILD_DIR/install-xrsimulator-x86_64/lib/libcrypto.a")
  XROS_SIM_SSL+=("$BUILD_DIR/install-xrsimulator-x86_64/lib/libssl.a")
  WATCH_SIM_CRYPTO+=("$BUILD_DIR/install-watchsimulator-x86_64/lib/libcrypto.a")
  WATCH_SIM_SSL+=("$BUILD_DIR/install-watchsimulator-x86_64/lib/libssl.a")
fi

make_library_slice "$MACOS_DIR" libcrypto.a "${MACOS_CRYPTO[@]}"
make_library_slice "$MACOS_DIR" libssl.a "${MACOS_SSL[@]}"
make_library_slice "$IOS_SIM_DIR" libcrypto.a "${IOS_SIM_CRYPTO[@]}"
make_library_slice "$IOS_SIM_DIR" libssl.a "${IOS_SIM_SSL[@]}"
make_library_slice "$XROS_SIM_DIR" libcrypto.a "${XROS_SIM_CRYPTO[@]}"
make_library_slice "$XROS_SIM_DIR" libssl.a "${XROS_SIM_SSL[@]}"
make_library_slice "$WATCHOS_DIR" libcrypto.a \
  "$BUILD_DIR/install-watchos-arm64_32/lib/libcrypto.a" \
  "$BUILD_DIR/install-watchos-arm64/lib/libcrypto.a"
make_library_slice "$WATCHOS_DIR" libssl.a \
  "$BUILD_DIR/install-watchos-arm64_32/lib/libssl.a" \
  "$BUILD_DIR/install-watchos-arm64/lib/libssl.a"
make_library_slice "$WATCH_SIM_DIR" libcrypto.a "${WATCH_SIM_CRYPTO[@]}"
make_library_slice "$WATCH_SIM_DIR" libssl.a "${WATCH_SIM_SSL[@]}"

xcodebuild -create-xcframework \
  -library "$MACOS_DIR/lib/libcrypto.a" \
  -headers "$MACOS_DIR/include" \
  -library "$BUILD_DIR/install-iphoneos-arm64/lib/libcrypto.a" \
  -headers "$BUILD_DIR/install-iphoneos-arm64/include" \
  -library "$IOS_SIM_DIR/lib/libcrypto.a" \
  -headers "$IOS_SIM_DIR/include" \
  -library "$BUILD_DIR/install-xros-arm64/lib/libcrypto.a" \
  -headers "$BUILD_DIR/install-xros-arm64/include" \
  -library "$XROS_SIM_DIR/lib/libcrypto.a" \
  -headers "$XROS_SIM_DIR/include" \
  -library "$WATCHOS_DIR/lib/libcrypto.a" \
  -headers "$WATCHOS_DIR/include" \
  -library "$WATCH_SIM_DIR/lib/libcrypto.a" \
  -headers "$WATCH_SIM_DIR/include" \
  -output "$OUTPUT_DIR/OpenSSLCrypto.xcframework"

xcodebuild -create-xcframework \
  -library "$MACOS_DIR/lib/libssl.a" \
  -headers "$MACOS_DIR/include" \
  -library "$BUILD_DIR/install-iphoneos-arm64/lib/libssl.a" \
  -headers "$BUILD_DIR/install-iphoneos-arm64/include" \
  -library "$IOS_SIM_DIR/lib/libssl.a" \
  -headers "$IOS_SIM_DIR/include" \
  -library "$BUILD_DIR/install-xros-arm64/lib/libssl.a" \
  -headers "$BUILD_DIR/install-xros-arm64/include" \
  -library "$XROS_SIM_DIR/lib/libssl.a" \
  -headers "$XROS_SIM_DIR/include" \
  -library "$WATCHOS_DIR/lib/libssl.a" \
  -headers "$WATCHOS_DIR/include" \
  -library "$WATCH_SIM_DIR/lib/libssl.a" \
  -headers "$WATCH_SIM_DIR/include" \
  -output "$OUTPUT_DIR/OpenSSLSSL.xcframework"

echo "Built static OpenSSL XCFrameworks in $OUTPUT_DIR"
