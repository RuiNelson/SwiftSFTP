#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<USAGE
Usage: ./Scripts/LinuxBuild/build.sh [swift build arguments...]

Build SwiftSFTP on Linux inside Docker. Run from the repository root.

Examples:
  ./Scripts/LinuxBuild/build.sh
  ./Scripts/LinuxBuild/build.sh test --scratch-path /tmp/swift-build
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

if ! command -v docker >/dev/null; then
    echo "docker not found in PATH." >&2
    exit 1
fi

ROOT="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="swiftsftp-linux-build"

docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"

if [[ $# -eq 0 ]]; then
    set -- build --scratch-path /tmp/swift-build
fi

docker run --rm \
    -v "$ROOT:/work" \
    -w /work \
    "$IMAGE_NAME" \
    "$@"
