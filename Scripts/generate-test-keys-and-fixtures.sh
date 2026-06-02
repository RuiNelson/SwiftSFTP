#!/usr/bin/env bash
set -euo pipefail

if [[ ! -d .git ]]; then
  echo "Run this script from the repository root (expected a .git directory)." >&2
  exit 1
fi

ROOT="$(pwd)"
KEYPAIRS="$ROOT/TestServer/KeyPairs"
FIXTURES="$ROOT/TestServer/Fixtures"
ENCRYPTED_PASSWORD="secret123"

command -v ssh-keygen >/dev/null || { echo "ssh-keygen not found" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$KEYPAIRS" "$FIXTURES"
rm -rf "$KEYPAIRS"/* "$FIXTURES"/*

key_file() {
  local algo="$1"
  local visibility="$2"
  local format="$3"
  local protection="$4"
  echo "$KEYPAIRS/${algo}-${visibility}-${format}-${protection}"
}

generate_key_pair() {
  local algo="$1"
  local pem_mode="$2"
  shift 2

  local openssh_private
  local openssh_public
  local pem_private
  local pkcs8_private
  local pkcs8_encrypted
  local pem_public
  local work

  openssh_private="$(key_file "$algo" private openssh clear)"
  openssh_public="$(key_file "$algo" public openssh clear)"
  pem_private="$(key_file "$algo" private pem clear)"
  pkcs8_private="$(key_file "$algo" private pkcs8 clear)"
  pkcs8_encrypted="$(key_file "$algo" private pkcs8 encrypted)"
  pem_public="$(key_file "$algo" public pem clear)"
  work="$TMPDIR/$algo"

  ssh-keygen "$@" -C "" -f "$openssh_private" -N "" -q
  mv "${openssh_private}.pub" "$openssh_public"

  cp "$openssh_private" "$work"
  ssh-keygen -p -m "$pem_mode" -N "" -f "$work" -q
  mv "$work" "$pem_private"

  openssl pkcs8 -topk8 -nocrypt -in "$pem_private" -out "$pkcs8_private"
  openssl pkcs8 -topk8 -v2 aes-256-cbc -passout "pass:$ENCRYPTED_PASSWORD" \
    -in "$pem_private" -out "$pkcs8_encrypted"
  openssl pkey -in "$pem_private" -pubout -out "$pem_public"
}

generate_key_pair rsa PEM -t rsa -b 2048
generate_key_pair p256 PEM -t ecdsa -b 256
generate_key_pair p384 PEM -t ecdsa -b 384
generate_key_pair p521 PEM -t ecdsa -b 521
generate_key_pair ed25519 PKCS8 -t ed25519

python3 - <<'PY' "$FIXTURES/DEADBEAF.bin" "$FIXTURES/SMALL.bin" "$FIXTURES/TINY.bin"
import pathlib
import sys

deadbeef_path, small_path, tiny_path = sys.argv[1:4]
pathlib.Path(deadbeef_path).write_bytes(b"\xde\xad\xbe\xaf" * (1024 * 1024))
pathlib.Path(small_path).write_bytes(b"\xaa" * 1024)
pathlib.Path(tiny_path).write_bytes(b"\x00")
PY

: >"$FIXTURES/NO_DATA.bin"

echo "Generated keys in $KEYPAIRS"
echo "Generated fixtures in $FIXTURES"
