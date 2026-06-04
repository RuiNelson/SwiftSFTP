# AGENTS.md / CLAUDE.md

## Project

SwiftSFTP wraps libssh2 as a modern SwiftPM library. Keep the low-level wrapper layer close to libssh2, but expose normal Swift types where practical.

## Human Code

- Code written by the human maintainer is sacred and should be treated as better than AI-written code.
- Do not delete or modify human-written code unless explicitly instructed to do so.
- Prefer additive, narrowly scoped changes that preserve the maintainer's existing structure and intent.

## Wrapper Style (`Sources/SwiftSFTP/Wrappers`)

- Put wrapper methods in `Sources/SwiftSFTP/Wrappers/Methods/`, one file per API category.
- Put wrapper types in `Sources/SwiftSFTP/Wrappers/Types/`, one file per type.
- Use PascalCase Swift wrapper names without the `libssh2_` prefix.
- Reference C APIs through the module, for example `libssh2.libssh2_session_free`.
- Add one-line docs to public wrapped methods and types.
- Do not add deprecated libssh2 APIs.
- Avoid convenience wrappers that only call another wrapper.
- Prefer Swift types (`String`, `Data`, `Int`, `UInt`, `Bool`, enums, structs) over raw C pointers and integers.
- Map libssh2 flag bitmasks to `OptionSet` types in `Wrappers/Types/`; map mutually exclusive operation selectors to enums.
- When libssh2 returns an error code, expose `throws` and map through the project error helpers.
- Use libssh2 symbolic constants through `libssh2.LIBSSH2_*`; do not pass magic integers to libssh2 calls.
- Hide required raw pointers inside Swift wrapper types when lifetime belongs to libssh2, as with agent identities.

### Ownership

- This layer is a thin wrapper; do not introduce a higher-level ownership model unless explicitly requested.
- Keep raw handles as lightweight wrapper structs unless a task specifically asks for managed ownership.
- Use `borrowing` for APIs that read or reuse wrapper values without taking ownership.
- Use `consuming` only when the wrapper truly takes ownership or invalidates the value.

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

## Git Hygiene

- Always run the format script `./format.sh` before committing
- The worktree may contain user changes. Do not revert changes you did not make.
- Use Conventional Commits for commit messages.

## Versioning

Use Semantic Versioning, use `etc/Release Template.md` for release templates for GitHub.
