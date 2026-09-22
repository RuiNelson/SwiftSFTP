#!/usr/bin/env python3
"""Check every declared OpenSSL dSYM exists and matches its framework binary."""
from pathlib import Path
import plistlib
import re
import subprocess


def uuids(path):
    output = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(path)], text=True)
    result = set(re.findall(r"UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)", output))
    if not result:
        raise SystemExit(f"No UUIDs found: {path}")
    return result


def main():
    artifacts = Path(__file__).resolve().parents[1] / "Artifacts/OpenSSL"
    count = 0
    for name in ("OpenSSLCrypto", "OpenSSLSSL"):
        root = artifacts / f"{name}.xcframework"
        metadata = plistlib.loads((root / "Info.plist").read_bytes())
        for item in metadata["AvailableLibraries"]:
            folder = root / item["LibraryIdentifier"]
            symbols = folder / item["DebugSymbolsPath"] / (item["LibraryPath"] + ".dSYM")
            dwarf = symbols / "Contents/Resources/DWARF" / name
            if not dwarf.is_file():
                raise SystemExit(f"Missing debug symbols: {dwarf}")
            binary = folder / item["BinaryPath"]
            if uuids(binary) != uuids(dwarf):
                raise SystemExit(f"UUID mismatch: {binary} and {dwarf}")
            count += 1
    print(f"PASS: {count} OpenSSL framework/dSYM pairs have matching UUIDs")


if __name__ == "__main__":
    main()
