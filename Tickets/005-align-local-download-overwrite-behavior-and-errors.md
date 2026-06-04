# Align local download overwrite behavior and errors

## Problem

`SFTPFileProtocol.read(to:)` documents that the local file is created or truncated, and `download(from:to:)` documents that the local destination is created or overwritten. The implementation instead throws when the local file already exists.

The implementation also throws `remotePathIsADirectory` when the local destination path is a directory.

## Impact

The API behavior contradicts its documentation. Callers expecting overwrite/truncate semantics will fail on existing files. Directory errors are also misleading because the failing path is local, not remote.

## Evidence

- `Sources/SwiftSFTP/SFTPClient/Convenience/FileUploadDownload.swift`: doc says the local file is created or truncated.
- `Sources/SwiftSFTP/SFTPClient/Convenience/ClientUploadDownload.swift`: doc says the local file is created or overwritten.
- `Sources/SwiftSFTP/SFTPClient/Convenience/FileUploadDownload.swift`: implementation throws `localFileAlreadyExists` for existing local files.
- `Sources/SwiftSFTP/SFTPClient/Convenience/FileUploadDownload.swift`: implementation throws `remotePathIsADirectory` for a local directory.

## Proposed fix

Choose one contract and make code and docs agree:

- If overwrite is intended, remove the existing-file error and truncate with `Data().write(to:)` or an explicit file handle truncation.
- If refusal is intended, update the docs for both helper layers.

Also add a local-directory error case, for example `localPathIsADirectory(path:)`, or reuse a more general local destination error.

Add tests for downloading to an existing file and downloading to a local directory.
