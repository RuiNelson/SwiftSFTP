#!/usr/bin/env python3
"""Prepare the pinned OpenSSL libcrypto sources for native SwiftPM builds.

Only maintainers run this script, after updating vendor/openssl. Consumers build
the committed C sources with SwiftPM, without Perl, Make, plugins, or binaries.
The submodule is read-only; Configure and source generation run in a temporary
directory. --check regenerates everything and detects stale committed sources.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / "vendor/openssl"
OUTPUT = ROOT / "Sources/OpenSSLCrypto"
OPTIONS = [
    "no-asm", "no-shared", "no-module", "no-tests", "no-apps", "no-docs",
    "no-dso", "no-async", "no-ktls", "no-autoload-config",
]
NAMESPACE = "SwiftSFTP_OpenSSL"


def run(command, directory, environment):
    result = subprocess.run(command, cwd=directory, env=environment,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit(f"Command failed: {' '.join(command)}\n{result.stdout}")
    return result.stdout


def adapt(contents):
    # Public headers are deliberately absent from the canonical openssl/ tree.
    # Xcode may put another SDK's openssl/ headers before private search paths.
    contents = re.sub(r'(#\s*include\s*[<"])(?:\.\./)*(?:include/)?openssl/([^>"\n]+)([>"])',
                      rf'\1{NAMESPACE}/\2\3', contents)
    contents = re.sub(r'(#\s*include\s*[<"])(?:\.\./)*include/(crypto|internal)/([^>"\n]+)([>"])',
                      r'\1private/\2/\3\4', contents)
    # These are textual implementations, not independent translation units.
    contents = re.sub(r'(#\s*include\s*"[^"\n]+)\.c"', r'\1.inc"', contents)
    # Do not hide imports from libc, pthreads, or platform frameworks along
    # with our own declarations. Hidden undefined system symbols cannot link.
    def system_include(match):
        if match.group(1).startswith((f"{NAMESPACE}/", "internal/", "crypto/", "prov/")):
            return match.group(0)
        return ("#pragma GCC visibility push(default)\n" + match.group(0) +
                "\n#pragma GCC visibility pop")
    contents = re.sub(r'^\s*#\s*include\s*<([^>\n]+)>[^\n]*', system_include,
                      contents, flags=re.MULTILINE)
    # Configure's generated comments otherwise depend on the checkout location.
    contents = re.sub(r'(?:\.\./)+[^\n,]*?/vendor/openssl/', "vendor/openssl/", contents)
    contents = contents.replace(str(UPSTREAM), "vendor/openssl")
    return contents


def generate(directory):
    environment = os.environ.copy()
    # Reproducible source metadata, independent of the maintainer's machine/date.
    environment["SOURCE_DATE_EPOCH"] = "0"
    run(["perl", str(UPSTREAM / "Configure"), "linux-generic64", *OPTIONS],
        directory, environment)
    run(["make", "-j8", "build_generated", "crypto/buildinf.h"], directory, environment)
    data = json.loads(run([
        "perl", "-I.", "-Mconfigdata", "-MJSON::PP", "-e",
        "print JSON::PP->new->canonical->encode({unified_info => "
        "\\%configdata::unified_info});",
    ], directory, environment))["unified_info"]

    # Use Configure's actual dependency graph, including built-in providers.
    # Looking for *.c would also compile mutually exclusive implementations.
    sources = {}
    visited = {}

    def visit(node, defines=()):
        defines = tuple(sorted(set(defines) | set(data.get("defines", {}).get(node, []))))
        if node in visited:
            if visited[node] != defines:
                raise SystemExit(f"Conflicting compilation settings for {node}")
            return
        visited[node] = defines
        # Built-in providers depend on libcommon.a, which in turn depends on
        # libcrypto. Include the dependency closure without following cycles.
        for dependency in data.get("depends", {}).get(node, []):
            if dependency in data["sources"]:
                visit(dependency, defines)
        if node in data["sources"]:
            for child in data["sources"][node]:
                visit(child, defines)
            return
        path = (directory / node).resolve()
        if path.suffix != ".c":
            raise SystemExit(f"Expected a portable C source, found {node}")
        relative = path.relative_to(UPSTREAM if path.is_relative_to(UPSTREAM) else directory)
        if relative in sources and sources[relative][1] != defines:
            raise SystemExit(f"Conflicting compilation settings for {relative}")
        sources[relative] = (path, defines)

    visit("libcrypto")
    generated = [str(path.relative_to(directory)) for path, _ in sources.values()
                 if not path.is_file()]
    generated += [path for path in data["generate"]
                  if Path(path).suffix in {".h", ".inc"} and not (directory / path).is_file()]
    if generated:
        run(["make", "-j8", *sorted(set(generated))], directory, environment)
    files = {}

    def copy_included_implementations(path):
        for name in re.findall(r'#\s*include\s*"([^"\n]+\.c)"', path.read_text()):
            included = (path.parent / name).resolve()
            if not included.is_file():
                raise SystemExit(f"Cannot find the included implementation {name} in {path}")
            relative = included.relative_to(UPSTREAM).with_suffix(".inc")
            if str(relative) not in files:
                files[str(relative)] = adapt(included.read_text())
                copy_included_implementations(included)

    for relative, (path, defines) in sources.items():
        # Hide definitions inside the image that contains SwiftSFTP. This works
        # with both static and dynamic consumers, without unsafe SwiftPM flags.
        prefix = "/* Prepared by Scripts/generate-openssl-sources.py. */\n"
        prefix += "#pragma GCC visibility push(hidden)\n"
        prefix += "".join(f"#define {value.replace('=', ' ', 1)}\n" for value in defines)
        files[str(relative)] = prefix + adapt(path.read_text())
        copy_included_implementations(path)

    # Copy private headers as well as generated headers/inc files. Generated
    # versions take precedence over the upstream source templates.
    for base in [UPSTREAM, directory]:
        for folder in ["include", "crypto", "providers", "ssl"]:
            for path in sorted((base / folder).rglob("*")):
                if not path.is_file() or path.suffix not in {".h", ".inc"}:
                    continue
                relative = path.relative_to(base)
                if str(relative).startswith("include/openssl/"):
                    destination = Path("include") / NAMESPACE / path.name
                elif str(relative).startswith("include/"):
                    destination = Path("private") / relative.relative_to("include")
                else:
                    destination = relative
                files[str(destination)] = adapt(path.read_text())
    if (UPSTREAM / "e_os.h").is_file():
        files["e_os.h"] = adapt((UPSTREAM / "e_os.h").read_text())

    # Swift Build partially links C targets before linking the product. Hidden
    # symbols become local at that boundary, so public entry points need unique
    # external names instead. redefine_extname keeps their C/Swift source names
    # intact while both definitions and imported calls use the private prefix.
    symbols = sorted({line.split()[0] for line in (UPSTREAM / "util/libcrypto.num").read_text().splitlines()
                      if line.strip() and not line.startswith("#")})
    names = "/* Generated SDK-private linker names; C and Swift API names stay unchanged. */\n"
    names += "#ifndef SWIFTSFTP_OPENSSL_SYMBOL_NAMES_H\n#define SWIFTSFTP_OPENSSL_SYMBOL_NAMES_H\n"
    names += "#if defined(__APPLE__)\n"
    names += "".join(f"#pragma redefine_extname {name} _SwiftSFTP_OpenSSL_{name}\n" for name in symbols)
    names += "#else\n"
    names += "".join(f"#pragma redefine_extname {name} SwiftSFTP_OpenSSL_{name}\n" for name in symbols)
    names += "#endif\n#endif\n"
    for path in list(files):
        if path.startswith(f"include/{NAMESPACE}/"):
            files[path] = ("#pragma GCC visibility push(default)\n"
                           f"#include <{NAMESPACE}/symbol_names.h>\n" + files[path] +
                           "\n#pragma GCC visibility pop\n")
    files[f"include/{NAMESPACE}/symbol_names.h"] = names

    # Pure C bignum code supports both LP64 and ILP32 (watchOS arm64_32).
    config_path = f"include/{NAMESPACE}/configuration.h"
    config = files[config_path]
    config, count = re.subn(
        r"#if !defined\(OPENSSL_SYS_UEFI\).*?\n#endif",
        "/* SwiftPM selects the destination architecture, including arm64_32. */\n"
        "#undef BN_LLONG\n#undef SIXTY_FOUR_BIT\n"
        "#if defined(__LP64__)\n# define SIXTY_FOUR_BIT_LONG\n# undef THIRTY_TWO_BIT\n"
        "#else\n# undef SIXTY_FOUR_BIT_LONG\n# define THIRTY_TWO_BIT\n#endif",
        config, flags=re.DOTALL,
    )
    if count != 1:
        raise SystemExit("OpenSSL bignum configuration changed; review the portable configuration")
    files[config_path] = config
    files["crypto/buildinf.h"] = run(
        ["perl", str(UPSTREAM / "util/mkbuildinf.pl"), "SwiftPM", "SwiftPM portable C"],
        directory, environment,
    )

    headers = sorted(path for path in files if path.startswith(f"include/{NAMESPACE}/"))
    files["include/module.modulemap"] = (
        "module OpenSSLCrypto [system] {\n" +
        "".join(f'    header "{path.removeprefix("include/")}"\n' for path in headers) +
        "    export *\n}\n"
    )
    files["LICENSE.txt"] = (UPSTREAM / "LICENSE.txt").read_text()
    version = (UPSTREAM / "VERSION.dat").read_text()
    if not re.search(r"^PRE_RELEASE_TAG=\s*$", version, re.MULTILINE):
        raise SystemExit("vendor/openssl must be pinned to a stable release")
    revision = run(["git", "rev-parse", "HEAD"], UPSTREAM, environment).strip()
    tag = run(["git", "describe", "--tags", "--exact-match", "HEAD"], UPSTREAM, environment).strip()
    if not re.fullmatch(r"openssl-\d+\.\d+\.\d+", tag):
        raise SystemExit(f"Expected a stable OpenSSL release tag, found {tag}")
    files["UPSTREAM.json"] = json.dumps({
        "repository": "https://github.com/openssl/openssl",
        "tag": tag, "revision": revision, "configure_options": OPTIONS,
        "source_count": len(sources),
        "sources": sorted(str(path) for path in sources),
        "excluded": sorted(path for path in files if path.endswith(".inc")),
        "files": {path: hashlib.sha256(content.encode()).hexdigest()
                  for path, content in sorted(files.items())},
    }, indent=2, sort_keys=True) + "\n"
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify the committed source snapshot")
    args = parser.parse_args()
    if not (UPSTREAM / "Configure").is_file():
        raise SystemExit("Initialize vendor/openssl before generating its SwiftPM sources")
    with tempfile.TemporaryDirectory(prefix="swiftsftp-openssl-") as temporary:
        files = generate(Path(temporary).resolve())
    # Manifest evaluation caches do not track arbitrary JSON files it reads.
    # Refresh this generated stamp when the snapshot changes, so SwiftPM/Xcode
    # re-evaluate the source/exclude lists after an OpenSSL update.
    manifest_path = ROOT / "Package.swift"
    manifest = manifest_path.read_text()
    digest = hashlib.sha256(files["UPSTREAM.json"].encode()).hexdigest()
    expected_manifest, count = re.subn(
        r"// OpenSSL source manifest SHA-256: \S+",
        f"// OpenSSL source manifest SHA-256: {digest}", manifest,
    )
    if count != 1:
        raise SystemExit("Missing source manifest fingerprint in Package.swift")
    if args.check:
        if manifest != expected_manifest:
            raise SystemExit("Stale OpenSSL manifest fingerprint; run Scripts/generate-openssl-sources.py")
        actual = {str(path.relative_to(OUTPUT)): path.read_bytes()
                  for path in OUTPUT.rglob("*") if path.is_file()}
        expected = {path: contents.encode() for path, contents in files.items()}
        changed = sorted(path for path in set(expected) | set(actual) if expected.get(path) != actual.get(path))
        if changed:
            raise SystemExit("Stale OpenSSL sources; run Scripts/generate-openssl-sources.py:\n" +
                             "\n".join(changed[:20]))
        print(f"PASS: {len(files)} OpenSSL source/header files match the pinned stable release")
    else:
        for path in OUTPUT.rglob("*"):
            if path.is_file() and str(path.relative_to(OUTPUT)) not in files:
                path.unlink()
        for relative, contents in files.items():
            path = OUTPUT / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.is_file() or path.read_text() != contents:
                path.write_text(contents)
        if manifest != expected_manifest:
            manifest_path.write_text(expected_manifest)
        print(f"Prepared {len(files)} OpenSSL source/header files for SwiftPM")


if __name__ == "__main__":
    main()
