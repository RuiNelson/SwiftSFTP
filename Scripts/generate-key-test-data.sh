#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DATA="$ROOT/Tests/SwiftSFTPTests/KeyValidation-Data.swift"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }
command -v ssh-keygen >/dev/null || { echo "ssh-keygen not found" >&2; exit 1; }

PASSWORD="testpassword123"

generate() {
    local name="$1" algo="$2" pkeyopt="$3" traditional="$4"

    openssl genpkey -algorithm "$algo" $pkeyopt -out "$TMPDIR/${name}_private.pem" 2>/dev/null
    openssl pkcs8 -topk8 -in "$TMPDIR/${name}_private.pem" \
        -v2 aes-256-cbc -passout "pass:$PASSWORD" \
        -out "$TMPDIR/${name}_encrypted.pem" 2>/dev/null
    openssl pkey -in "$TMPDIR/${name}_private.pem" \
        -pubout -out "$TMPDIR/${name}_public.pem" 2>/dev/null

    if [[ "$traditional" == "yes" ]]; then
        openssl pkey -in "$TMPDIR/${name}_private.pem" -traditional \
            -out "$TMPDIR/${name}_traditional.pem" 2>/dev/null
    fi
}

generate rsa RSA "-pkeyopt rsa_keygen_bits:2048" yes
generate p256 EC "-pkeyopt ec_paramgen_curve:P-256" yes
generate p384 EC "-pkeyopt ec_paramgen_curve:P-384" yes
generate p521 EC "-pkeyopt ec_paramgen_curve:P-521" yes
generate ed25519 ED25519 "" no

# OpenSSH format keys (unencrypted)
ssh-keygen -t rsa -b 2048 -f "$TMPDIR/openssh_rsa" -N "" -q 2>/dev/null
ssh-keygen -t ecdsa -b 256 -f "$TMPDIR/openssh_p256" -N "" -q 2>/dev/null
ssh-keygen -t ecdsa -b 384 -f "$TMPDIR/openssh_p384" -N "" -q 2>/dev/null
ssh-keygen -t ecdsa -b 521 -f "$TMPDIR/openssh_p521" -N "" -q 2>/dev/null
ssh-keygen -t ed25519 -f "$TMPDIR/openssh_ed25519" -N "" -q 2>/dev/null

rm -f "$TEST_DATA"

swift "$ROOT/Scripts/KeyValidationTestGenerator.swift" "$TMPDIR" "$TEST_DATA" "$PASSWORD"

echo "Generated $TEST_DATA"
