#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DATA="$ROOT/Tests/SwiftSFTPTests/KeyVal/HostkeyValidation-Data.swift"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }
command -v ssh-keygen >/dev/null || { echo "ssh-keygen not found" >&2; exit 1; }

generate_host_key() {
    local name="$1"
    shift

    ssh-keygen "$@" -C "" -f "$TMPDIR/$name" -N "" -q
    awk '{print $1" "$2}' "$TMPDIR/${name}.pub" > "$TMPDIR/${name}_shorthand"
}

generate_host_key rsa -t rsa -b 2048
generate_host_key p256 -t ecdsa -b 256
generate_host_key p384 -t ecdsa -b 384
generate_host_key p521 -t ecdsa -b 521
generate_host_key ed25519 -t ed25519

echo "127.0.0.1 $(cat "$TMPDIR/ed25519_shorthand")" > "$TMPDIR/known_hosts"
ssh-keygen -H -f "$TMPDIR/known_hosts" >/dev/null 2>&1
grep '|1|' "$TMPDIR/known_hosts" > "$TMPDIR/hashed_line"

swift "$ROOT/Scripts/HostkeyValidationTestGenerator.swift" "$TMPDIR" "$TEST_DATA"

echo "Generated $TEST_DATA"
