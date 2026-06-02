#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_SERVER="$ROOT/TestServer"
IMAGE_NAME="swiftsftp-testserver"
CONTAINER_NAME="swiftsftp-testserver"
HOST_PORT=6922

if [[ ! -d "$TEST_SERVER/KeyPairs" || ! -d "$TEST_SERVER/Fixtures" ]]; then
  echo "Missing TestServer/KeyPairs or TestServer/Fixtures." >&2
  echo "Run ./Scripts/generate-test-keys-and-fixtures.sh from the repository root first." >&2
  exit 1
fi

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

docker build -t "$IMAGE_NAME" "$TEST_SERVER"

docker run -d \
  --name "$CONTAINER_NAME" \
  -p "${HOST_PORT}:22" \
  "$IMAGE_NAME" >/dev/null

echo "Test server running on port ${HOST_PORT} (container: ${CONTAINER_NAME})"
