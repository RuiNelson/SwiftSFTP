---
name: github-release
description: Prepare GitHub releases for this repository. Use when drafting release notes, choosing a semantic version, validating release readiness, creating tags, or publishing GitHub releases with gh/GitHub from SwiftSFTP or similar SwiftPM projects.
---

# GitHub Release

Use this skill to prepare and publish GitHub releases. Keep the process self-contained; do not depend on release template files in the repository.

## Workflow

1. Inspect repository state with `git status --short`, current branch, latest tags, and recent commits.
2. Confirm the intended version if the user did not specify it. Use Semantic Versioning:
   - Patch for backwards-compatible bug fixes.
   - Minor for backwards-compatible features or improvements.
   - Major for breaking API or behavior changes.
3. Build release notes from merged changes since the previous tag. Prefer commit history, changelog entries, merged PRs, and user-provided context over guesswork.
4. Validate release readiness before publishing:
   - Run the repository's required formatting command when relevant.
   - Run the repository's build/test commands expected for release.
   - Check for uncommitted changes that should not be included.
5. Create or verify the release tag. Do not overwrite an existing tag unless the user explicitly asks.
6. Publish through GitHub using the available GitHub tools or `gh release create`.
7. Report the version, tag, validation performed, and release URL.

## SwiftSFTP Conventions

- Follow Semantic Versioning.
- Use Conventional Commits for release-related commits.
- Run `./format.sh` before committing release changes.
- Run `swift build` after wrapper API changes.
- Run `swift test --scratch-path /private/tmp/SwiftSFTP-NG-test` after behavior, package, or public API changes.
- OpenSSL artifacts are consumed from `Artifacts/OpenSSL/*.xcframework`; do not rebuild or modify vendored OpenSSL/libssh2 sources unless the release explicitly requires it.

## Release Title

Use:

```text
Version X.X.X
```

## Release Notes Format

Use only the sections that apply.

````markdown
## What's New

- **Feature description** - You can now...
- **Improvement description** - Now, you don't have to...

Add short code examples when they help adopters understand a new capability:

```swift
// Example usage
```

## Bug Fixes

- Fixed an issue where...
- Resolved a crash when...

## Migration Guide

Describe breaking changes and what adopters need to update.

**Before:**

```swift
// Old usage
```

**After:**

```swift
// New usage
```
````

## Notes Style

- Write for adopters of the library, not for maintainers.
- Group changes by user impact.
- Include only changes that affect how adopters use the library or the behavior they experience.
- Omit CI, release automation, repository maintenance, internal benchmarks, formatting-only changes, and other
  maintainer-facing work.
- Omit build-system or packaging changes unless they alter a supported platform, compatibility requirement, dependency,
  installation workflow, or another outcome visible to adopters.
- Omit empty sections.
- Keep bullets concrete and concise.
- Mention breaking changes in `Migration Guide`; do not bury them under features.
- Include code examples only when they clarify usage or migration.
