# Make upload and copy destination creation exclusive

## Problem

`upload(from:to:)` and `copyClientSide(from:to:)` promise that the remote destination must not already exist. Both helpers check with `stat`, then open the destination with `[.create, .write]`.

Because the open does not include `.exclusive`, another client can create the destination between the `stat` and `open`. In that race, the helper will open and write to an existing file.

## Impact

The API can overwrite or append to a file that it promises not to replace. This is a time-of-check/time-of-use race and can cause remote data loss.

## Evidence

- `Sources/SwiftSFTP/SFTPClient/Convenience/ClientUploadDownload.swift`: `upload` checks `stat`, then calls `openFile([.create, .write], ...)`.
- `Sources/SwiftSFTP/SFTPClient/Convenience/ClientCopy.swift`: `copyClientSide` checks `stat`, then calls `openFile([.create, .write], ...)`.
- `Sources/SwiftSFTP/Wrappers/Types/LibSSH2SFTPFileOpenFlags.swift`: `.exclusive` exists and maps to `LIBSSH2_FXF_EXCL`.

## Proposed fix

Open destinations with `[.create, .write, .exclusive]` in both helpers. Keep the preflight `stat` if the nicer error mapping is useful, but rely on exclusive open for correctness.

Map the exclusive-open failure for an existing path to `FileTransferErrors.remoteFileAlreadyExists(path:)` when possible.

Add a regression test that exercises the open flags or simulates the race with a mock/protocol implementation.
