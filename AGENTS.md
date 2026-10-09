# AGENTS.md / CLAUDE.md

## Project

SwiftSFTP wraps libssh2 as a modern SwiftPM library. Source is organized in numbered layers under `Sources/SwiftSFTP/`:

- **Layer 0** — thin libssh2 wrappers close to the C API, with Swift types where practical.
- **Layer 1** — higher-level `SFTPClient` / `SFTPFile` API built on Layer 0.
- **Extensions** — shared helpers (pointers, strings, errors) used by both layers.
- **CryptographicUtils** — OpenSSL-backed key generation, import, export, and validation, plus hashing.

`Vendor/libssh2` and `Vendor/SwiftSFTP-OpenSSL/Vendor/openssl` are read-only upstream submodules;
do not edit them except when explicitly upgrading vendored sources. OpenSSL preparation belongs to
the separate `SwiftSFTP-OpenSSL` repository, included here as `Vendor/SwiftSFTP-OpenSSL`.

## Layer 0 — libssh2 wrappers (`Sources/SwiftSFTP/Layer 0`)

- Put wrapper methods in `Layer 0/Methods/`, one file per API category.
- Put wrapper types in `Layer 0/Types/`, one file per type.
- Put wrapper conveniences in `Layer 0/Methods/Convenience/`; thin compositions over other wrappers are fine when they improve ergonomics (Swift types, fewer parameters, common workflows).
- Use PascalCase Swift wrapper names without the `libssh2_` prefix.
- Reference C APIs through the module, for example `libssh2.libssh2_session_free`.
- Add one-line docs to public wrapped methods and types.
- Do not add deprecated libssh2 APIs.
- Prefer Swift types (`String`, `Data`, `Int`, `UInt`, `Bool`, enums, structs) over raw C pointers and integers.
- Map libssh2 flag bitmasks to `OptionSet` types in `Layer 0/Types/`; map mutually exclusive operation selectors to enums.
- When libssh2 returns an error code, expose `throws` and map to `LibSSH2Error` in `Layer 0/Types/LibSSH2Error.swift`.
- Use libssh2 symbolic constants through `libssh2.LIBSSH2_*`; do not pass magic integers to libssh2 calls.
- Hide required raw pointers inside Swift wrapper types when lifetime belongs to libssh2, as with agent identities.
- Route libssh2 entry points documented as not thread-safe through `SynchronousExecution` in `Layer 0/NotThreadSafe.swift`.

### Ownership

- This layer is a thin wrapper; do not introduce a higher-level ownership model unless explicitly requested.
- Keep raw handles as lightweight wrapper structs unless a task specifically asks for managed ownership.
- Use `borrowing` for APIs that read or reuse wrapper values without taking ownership.
- Use `consuming` only when the wrapper truly takes ownership or invalidates the value.

## Layer 1 — SFTP client (`Sources/SwiftSFTP/Layer 1`)

- Keep `SFTPClient`, `SFTPFile`, and their protocols in the layer root; put supporting types in `Layer 1/StructsAndEnums/`.
- Put transfer and filesystem conveniences in `Layer 1/Convenience/`.
- Call libssh2 only through Layer 0 wrappers, not directly from Layer 1.
- Keep libssh2 errors in `Layer 0/Types/LibSSH2Error.swift`; define Layer 1 domain errors as enums under `Layer 1/` (for example in `StructsAndEnums/`), not in `LibSSH2Error`.
- Prefer protocols (`SFTPClientProtocol`, `SFTPFileProtocol`) for testability; keep concrete types aligned with protocol contracts.
- Do not add a second high-level client API unless explicitly requested.

## CryptographicUtils (`Sources/SwiftSFTP/CryptographicUtils`)

- `Keys/` holds the public key API (`AsymmetricCryptography`, `PublicKey`, `PrivateKey`, …), one file per type.
- `Validation/` holds the `String` validation APIs (`KeyValidation`, `known_hosts` checks) and `SSHUserKeyAlgorithm`.
- `OpenSSH/` holds the OpenSSH formats: the SSH wire encoding, the key codec, key file ciphers, and
  `OpenSSHKeyPolicy`. It does not import OpenSSL.
- `OpenSSL/` is the only place that imports `OpenSSLCrypto`: `OpenSSLKey` wraps `EVP_PKEY`, alongside ciphers, digests, and
  support types.
- `Deprecated/` holds deprecated API, forwarding to its replacement.
- Parsing (`PublicKey`, `PrivateKey`) checks that keys are valid and consistent but applies no policy; SSH acceptance
  rules live only in `OpenSSHKeyPolicy`.
- Check imported keys in the `init(importing:)` initializers of `PublicKey` and `PrivateKey`, so every format gets the
  same checks.

## OpenSSL Source Distribution

- OpenSSL source preparation lives in the public `RuiNelson/SwiftSFTP-OpenSSL` repository, included as the
  `Vendor/SwiftSFTP-OpenSSL` submodule. Keep it pinned to a verified commit.
- The nested upstream `Vendor/SwiftSFTP-OpenSSL/Vendor/openssl` submodule is read-only and uses a **stable**
  OpenSSL release tag (`openssl-X.Y.Z`). Never leave it on a `-dev`, `alpha` or `beta` snapshot or branch tip:
  check its `VERSION.dat` after moving it and confirm `PRE_RELEASE_TAG` is empty.
  A newer major/minor line in development does not outrank the newest stable
  release — prefer the stable tag even when its version number is lower.
- Update and prepare OpenSSL inside SwiftSFTP-OpenSSL. After updating this repository's submodule pin, run
  `python3 Scripts/update-openssl-manifest.py` and rerun `swift build` + `swift test`.
- SwiftPM compiles `Vendor/SwiftSFTP-OpenSSL/Sources/OpenSSLCrypto/` directly on every supported platform.
  Do not add binary targets, precompiled libraries, build-time OpenSSL downloads or consumer-side
  Perl/Make/plugin requirements.
- The prepared snapshot is generated; edit the generator in SwiftSFTP-OpenSSL rather than its C sources or
  headers. It preserves the upstream licenses, qualifies public headers under `SwiftSFTP_OpenSSL/`,
  and gives public C symbols private linker
  names while hiding internal symbols to avoid capturing
  another SDK's OpenSSL/BoringSSL calls. Keep the whole header set in one Clang module.
- CI runs the submodule's generator with `--check` and `Scripts/update-openssl-manifest.py --check` to verify
  the snapshot and parent manifest fingerprint. Check out submodules recursively, then initialize the
  companion's maintenance-only upstream with `git -C Vendor/SwiftSFTP-OpenSSL submodule update --init --checkout Vendor/openssl`.
  Keep its `update = none` setting so consumer builds fetch the prepared snapshot only.
- SwiftSFTP-OpenSSL checks upstream stable releases daily and opens one Issue per newer release.
  Updates remain a maintainer action; do not follow `master` or update pins automatically during builds.
- After updating libssh2, run `python3 Scripts/generate-libssh2-backend.py`; CI checks its generated backend against
  the pinned submodule. The adapter is used on all platforms, and the submodule stays unmodified.
- Preserve the crypto coexistence consumer tests when changing linkage, visibility, or headers. See
  `Documentation/OpenSSLSourceBuild.md` for the portable C configuration and maintenance workflow.

## Testing

- Run `swift build` after wrapper API changes.
- Run `swift test` after behavior, package, or public API changes.
- Prefer scratch paths under `/private/tmp` for local verification, for example:

```bash
swift test --scratch-path /private/tmp/SwiftSFTP-NG-test
```

- Integration tests against the Docker SFTP test server are documented in `Documentation/TestServerInfo.md`; start the server with `Scripts/test-server-up.sh` before expecting those tests to pass.

## Git Hygiene

- Always run the format script `./format.sh` before committing
- The worktree may contain user changes. Do not revert changes you did not make.
- Use Conventional Commits for commit messages.

## Versioning

Use Semantic Versioning. Use the `github-release` skill to draft the notes, choose the version, and publish.
