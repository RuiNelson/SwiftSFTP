# AGENTS.md / CLAUDE.md

## Project

SwiftSFTP wraps libssh2 as a modern SwiftPM library. Source is organized in numbered layers under `Sources/SwiftSFTP/`:

- **Layer 0** — thin libssh2 wrappers close to the C API, with Swift types where practical.
- **Layer 1** — higher-level `SFTPClient` / `SFTPFile` API built on Layer 0.
- **Extensions** — shared helpers (pointers, strings, errors) used by both layers.
- **KeyValidation** — SSH key PEM validation helpers.

`vendor/libssh2` and `vendor/openssl` are read-only submodules; do not edit them except when explicitly upgrading vendored sources.

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

## OpenSSL Artifacts

- OpenSSL source lives in `vendor/openssl` as a submodule (read only).
- Use `Scripts/build-openssl-xcframeworks.sh` to build static OpenSSL XCFrameworks.
- Default OpenSSL artifact builds exclude x86 macOS and x86 simulator slices.
- Use `--intelMac` to include x86_64 macOS.
- Use `--intelSim` to include x86_64 simulator slices.
- SwiftPM consumes `Artifacts/OpenSSL/*.xcframework`; these must be present for package users.

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
