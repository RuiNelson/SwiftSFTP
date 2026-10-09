#!/usr/bin/env python3
"""Refresh the self-contained SwiftPM source manifest after updating SwiftSFTP-OpenSSL."""

import argparse
import hashlib
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "Vendor/SwiftSFTP-OpenSSL/Sources/OpenSSLCrypto/UPSTREAM.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify the fingerprint without changing it")
    args = parser.parse_args()
    if not SNAPSHOT.is_file():
        raise SystemExit("Initialize the SwiftSFTP-OpenSSL submodule with git submodule update --init --recursive")
    manifest_path = ROOT / "Package.swift"
    manifest = manifest_path.read_text()
    digest = hashlib.sha256(SNAPSHOT.read_bytes()).hexdigest()
    pattern = r"// BEGIN OPENSSL SOURCE MANIFEST\n.*?// END OPENSSL SOURCE MANIFEST"
    companion_manifest = SNAPSHOT.parents[2] / "Package.swift"
    prepared = re.search(pattern, companion_manifest.read_text(), re.DOTALL)
    if prepared is None or f"// OpenSSL source manifest SHA-256: {digest}" not in prepared.group(0):
        raise SystemExit("Stale SwiftSFTP-OpenSSL manifest; regenerate the source snapshot in that repository")
    updated, count = re.subn(pattern, lambda _: prepared.group(0), manifest, flags=re.DOTALL)
    if count != 1:
        raise SystemExit("Missing generated OpenSSL source manifest block in Package.swift")
    if args.check:
        if updated != manifest:
            raise SystemExit("Stale OpenSSL fingerprint; run python3 Scripts/update-openssl-manifest.py")
        print("PASS: Package.swift fingerprint matches SwiftSFTP-OpenSSL")
    else:
        if updated != manifest:
            manifest_path.write_text(updated)
        print(f"OpenSSL source manifest SHA-256: {digest}")


if __name__ == "__main__":
    main()
