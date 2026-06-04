# Free session in getServerHostKey

## Problem

`SFTPClient.getServerHostKey` creates a temporary libssh2 session with `SessionInit()`, but it only closes the socket. The session is not disconnected or freed.

It also creates the session before validating the timeout, so invalid timeout calls can allocate a session and then throw without cleanup.

## Impact

Repeated calls leak libssh2 session resources. Tools that scan or verify many host keys can accumulate native resources over time.

## Evidence

- `Sources/SwiftSFTP/SFTPClient/SFTPClient.swift`: `getServerHostKey` calls `SessionInit()`.
- The function only defers `CloseSocket(socket)`.
- There is no matching `SessionDisconnect` or `SessionFree` for the temporary session.

## Proposed fix

Validate `timeOut` before creating the session. After creating the session, guarantee cleanup on all paths:

- `defer { try? SessionDisconnect(...) }` after handshake if appropriate.
- `defer { try? SessionFree(session: session) }` immediately after successful `SessionInit()`.
- Keep `CloseSocket(socket)` for the socket after handshake succeeds.

Add a test for invalid timeout that does not require creating a session, if possible, and consider a repeated-call smoke test under leak tooling.
