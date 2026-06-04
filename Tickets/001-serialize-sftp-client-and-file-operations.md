# Serialize SFTP client and file operations

## Problem

`SFTPClientProtocol` and `SFTPFileProtocol` are `Sendable`, but the concrete implementations store libssh2 handles in `nonisolated(unsafe)` properties and only protect the closed flags with a dispatch queue. The libssh2 calls themselves run outside that queue.

This means one task can pass `checkClosed()` and start using a session, SFTP handle, or file handle while another task calls `close()` and frees the same underlying resource.

## Impact

Concurrent use can lead to use-after-free, crashes, corrupted libssh2 state, or undefined behavior. This is especially risky because the public protocols advertise cross-task sendability.

## Evidence

- `Sources/SwiftSFTP/SFTPClient/Protocols.swift`: `SFTPClientProtocol` and `SFTPFileProtocol` conform to `Sendable`.
- `Sources/SwiftSFTP/SFTPClient/SFTPClient.swift`: `session`, `_sftp`, `_socket`, and `_closed` are `nonisolated(unsafe)`.
- `Sources/SwiftSFTP/SFTPClient/SFTPFile.swift`: `handle` and `_closed` are `nonisolated(unsafe)`.
- `SFTPFile.read`, `write`, `fsync`, `set`, `stat`, and `statFilesystem` call libssh2 after a separate closed check.
- `SFTPClient.close()` and `SFTPFile.close()` free resources independently of in-flight operations.

## Proposed fix

Serialize all operations that touch a given client/session and file handle with an execution primitive that also covers close. Reasonable options:

- Convert `SFTPClient` and/or `SFTPFile` to actors if the API can tolerate actor isolation.
- Keep classes, but run each operation and close through a per-instance serial queue.
- Ensure `close()` cannot free resources until in-flight operations finish.

Add concurrent tests that race `read`/`stat`/`listDirectory` against `close()`.
