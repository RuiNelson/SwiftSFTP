#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="swiftsftp-testserver"

if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Test server container is not present (${CONTAINER_NAME})."
  exit 0
fi

docker rm -f "$CONTAINER_NAME" >/dev/null
echo "Stopped and removed test server container (${CONTAINER_NAME})."
