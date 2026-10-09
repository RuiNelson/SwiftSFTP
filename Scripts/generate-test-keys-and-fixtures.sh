#!/usr/bin/env bash
set -euo pipefail

if [[ ! -e .git ]]; then
  echo "Run this script from the repository root (expected a .git directory or submodule gitlink file)." >&2
  exit 1
fi

ROOT="$(pwd)"
KEYPAIRS="$ROOT/TestServer/KeyPairs"
FIXTURES="$ROOT/TestServer/Fixtures"
ENCRYPTED_PASSWORD="secret123"

command -v ssh-keygen >/dev/null || { echo "ssh-keygen not found" >&2; exit 1; }

# Prefer real OpenSSL over macOS's system LibreSSL for Ed25519 conversions.
OPENSSL="${OPENSSL_FOR_FIXTURES:-}"
if [[ -z "$OPENSSL" ]]; then
  for candidate in /opt/homebrew/bin/openssl /usr/local/bin/openssl \
      /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl \
      "$(command -v openssl || true)"; do
    if [[ -x "$candidate" ]] && [[ "$("$candidate" version)" == OpenSSL\ * ]]; then
      OPENSSL="$candidate"
      break
    fi
  done
fi
[[ -x "$OPENSSL" ]] && [[ "$("$OPENSSL" version)" == OpenSSL\ * ]] || {
  echo "Real OpenSSL is required to generate fixtures; set OPENSSL_FOR_FIXTURES." >&2
  exit 1
}

FIXTURE_WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_WORK_DIR"' EXIT

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
  work="$FIXTURE_WORK_DIR/$algo"

  ssh-keygen "$@" -C "" -f "$openssh_private" -N "" -q
  mv "${openssh_private}.pub" "$openssh_public"

  if [[ "$algo" == "ed25519" ]]; then
    # `ssh-keygen -p -m PKCS8` cannot re-export Ed25519 on the macOS system ssh-keygen (linked against
    # LibreSSL, which errors internally on this conversion), so PEM/PKCS8 forms can't be produced by
    # reformatting the OpenSSH file in place like the other algorithms below. Authentication tests log in
    # using every format for the same user (see Authentication.swift/MultiKeyAuth.swift), so this has to be
    # the *same* key as $openssh_private, not a freshly generated one: pull the raw 32-byte seed out of the
    # openssh-key-v1 container ourselves and wrap it in the fixed RFC 8410 PKCS8 DER prefix for Ed25519.
    python3 - "$openssh_private" "$pem_private" <<'PY'
import base64
import struct
import sys


def read_str(buf, off):
    (n,) = struct.unpack_from(">I", buf, off)
    off += 4
    return buf[off:off + n], off + n


in_path, out_path = sys.argv[1:3]
with open(in_path) as f:
    lines = [l for l in f.read().splitlines() if l and not l.startswith("-----")]
raw = base64.b64decode("".join(lines))

magic = b"openssh-key-v1\x00"
assert raw.startswith(magic), "not an openssh-key-v1 file"
off = len(magic)

ciphername, off = read_str(raw, off)
kdfname, off = read_str(raw, off)
_kdfoptions, off = read_str(raw, off)
assert ciphername == b"none" and kdfname == b"none", "key must be unencrypted"

(nkeys,) = struct.unpack_from(">I", raw, off)
off += 4
assert nkeys == 1

_pubblob, off = read_str(raw, off)
privsection, off = read_str(raw, off)

p = 8  # skip the duplicated checkint pair
keytype, p = read_str(privsection, p)
assert keytype == b"ssh-ed25519"
pub, p = read_str(privsection, p)
priv, p = read_str(privsection, p)
assert len(priv) == 64 and priv[32:] == pub
seed = priv[:32]

der = bytes.fromhex("302e020100300506032b657004220420") + seed
b64 = base64.b64encode(der).decode()
pem = "-----BEGIN PRIVATE KEY-----\n"
pem += "\n".join(b64[i:i + 64] for i in range(0, len(b64), 64))
pem += "\n-----END PRIVATE KEY-----\n"
with open(out_path, "w") as f:
    f.write(pem)
PY
  else
    cp "$openssh_private" "$work"
    ssh-keygen -p -m "$pem_mode" -N "" -f "$work" -q
    mv "$work" "$pem_private"
  fi

  "$OPENSSL" pkcs8 -topk8 -nocrypt -in "$pem_private" -out "$pkcs8_private"
  "$OPENSSL" pkcs8 -topk8 -v2 aes-256-cbc -passout "pass:$ENCRYPTED_PASSWORD" \
    -in "$pem_private" -out "$pkcs8_encrypted"
  "$OPENSSL" pkey -in "$pem_private" -pubout -out "$pem_public"
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
