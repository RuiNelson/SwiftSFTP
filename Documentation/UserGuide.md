# SwiftSFTP — User's Guide

This guide walks through everything you need to integrate and use SwiftSFTP in your application, from initial setup through advanced workflows.

The optional products that connect SwiftSFTP to AVFoundation and EXIFKit are covered in [Integrations](Integrations.md).

## Table of Contents

1. [Connecting to a Server](#connecting-to-a-server)
2. [Authentication](#authentication)
3. [Host Key Verification](#host-key-verification)
4. [Navigating the Remote Filesystem](#navigating-the-remote-filesystem)
5. [Working with Files](#working-with-files)
6. [Uploading and Downloading](#uploading-and-downloading)
7. [Swarms of Connections](#swarms-of-connections)
8. [Copying, Renaming, and Deleting](#copying-renaming-and-deleting)
9. [Shell Agent (Server-Side Operations)](#shell-agent-server-side-operations)
10. [Symlinks](#symlinks)
11. [Filesystem Statistics](#filesystem-statistics)
12. [Keeping the Connection Alive](#keeping-the-connection-alive)
13. [Validating SSH Keys (Offline)](#validating-ssh-keys-offline)
14. [Error Handling](#error-handling)

---

## Connecting to a Server

### Quick start

The initializer connects, authenticates, and initializes SFTP: a client that exists is logged in.

```swift
import SwiftSFTP

let client = try await SFTPClient(
    TCPLocation(hostname: "sftp.example.com", port: 22),
    hostKeyAcceptance: .acceptAny,          // see Host Key Verification
    authentication: UserAuthentication(
        name: "alice",
        auth: .password("s3cr3t")
    )
)
defer { try? await client.close() }

// … your operations …
```

With every parameter:

```swift
let susanaED25519 = URL(filePath: "/Users/susana/.ssh/id_ed25519")      // has passphrase (encrypted)
let susanaRSA = URL(filePath: "/Users/susana/.ssh/id_rsa")              // in plaintext
let serverHostkey = "[::1]:5022 ecdsa-sha2-nistp256 AAAAE2VjZ(...)lPM=" // same format as known_hosts

let myClient = try await SFTPClient(
    TCPLocation(hostname: "::1", port: 5022),
    hostKeyAcceptance: .loadKnownHostsString(serverHostkey),
    authentication: UserAuthentication(
        name: "susana",
        auth: .privateKeys(
            [PrivateKey(file: susanaED25519, passphrase: "nobodyknows"),
             PrivateKey(file: susanaRSA)]
        )
    ),
    compressionPreference: (clientToServer: [.zlib], serverToClient: [.zlib]),
    loginTimeOut: 10.0,
    operationsTimeOut: 10.5,
    deinitErrorHandler: { myLogger.error("error on deinit: \($0.localizedDescription)") }
)
```

### Checking a configuration without connecting

`preflightConfigurationCheck` runs the checks the initializer runs before it connects — hostname, port, username,
authentication material, and host-key acceptance data, loaded into a libssh2 session that is then freed — and throws
`SFTPClientInvalidConfig` when one fails. Use it to validate user input, such as a connection form, before connecting:

```swift
try SFTPClient.preflightConfigurationCheck(
    TCPLocation(hostname: "sftp.example.com", port: 22),
    hostKeyAcceptance: .loadKnownHostsString(savedHostKeyLine),
    authentication: UserAuthentication(name: "alice", auth: .password("s3cr3t"))
)
```

### `TCPLocation`

```swift
TCPLocation(hostname: "sftp.example.com")           // port defaults to 22
TCPLocation(hostname: "192.168.1.10", port: 2222)
```

Accepts IPv4 addresses, IPv6 addresses, and DNS names. Port must be 1–65535.

### Initializer parameters summary

| Parameter | Type | Default | Notes |
|-----------|------|---------|-------|
| `_ openSocketIn` | `TCPLocation` | — | Server address, passed without a label |
| `hostKeyAcceptance` | `HostKeyAcceptance` | `.acceptAny` | See [Host Key Verification](#host-key-verification) |
| `authentication` | `UserAuthentication` | — | See [Authentication](#authentication) |
| `compressionPreference` | `(clientToServer: [CompressionAlgorithm], serverToClient: [CompressionAlgorithm])` | `([], [])` | Ordered preferences for each direction; an empty array means `[.none]` |
| `loginTimeOut` | `TimeInterval` | `10.0` | Timeout for the login phase only; positive, or `.infinity` for none |
| `operationsTimeOut` | `TimeInterval?` | `10.0` | Post-login timeout for each blocking libssh2 call; must be positive when set. Pass `nil` or `.infinity` for no blocking timeout (libssh2 default) |
| `deinitErrorHandler` | `DeinitErrorHandler` | `debugPrintDeinitErrorHandler` | Receives the failures of objects closing themselves after being released, see [Closing and releasing](#closing-and-releasing) |

### Closing and releasing

`close()` is optional on a client, a file, and a shell agent. Call it when the outcome matters: it waits for the server,
and throws when releasing something failed. Release the object without it and it closes itself:

- A **client** drops its socket and frees everything at once, without the polite goodbye `close()` gives the server.
  Nothing waits for the network, so releasing a client never blocks.
- A **file** sends its `SSH_FXP_CLOSE` from a task of its own, which holds the client until the server answers.
- A **shell agent** closes its channel on the client's session queue.

A failure there has nobody to be thrown to, so it goes to the `deinitErrorHandler` given to the client, which its files,
shell agents, and forks share. The default, `debugPrintDeinitErrorHandler`, prints it in a debug build and ignores it in a
release build. Pass your own to log it. The handler can be called from any thread.

Close a file before anything that depends on it being closed: before renaming a file just written (Windows servers
refuse to rename an open file), before reading it from another connection, or when a write error the server reports only
at close must not go unnoticed.

### Errors, misuse, and impossible values

SwiftSFTP tells three kinds of failure apart:

- **Runtime errors** are thrown. A correct program has to expect them: a dropped connection, a rejected password, a
  missing remote file, an empty path typed by a user.
- **Misuse** of the library, a bug in the calling code, stops a debug build with an assertion failure where it happens.
  A release build throws a `MisuseError` instead, so that neither a made-up value nor a step that never ran reaches the
  caller as a success.
- **Impossible values** stop the process with a precondition failure in every build: no correct program passes them,
  and there is nothing sensible to do with one. See [Preconditions](#preconditions).

| Misuse | Debug | Release |
|------|------|------|
| Using a client, or a file or shell agent opened from it, after the client's `close()` — including an operation that was waiting for the connection when another task closed it | Assertion failure | Throws `MisuseError.clientUsedAfterClosing` |
| Using a file after its `close()` | Assertion failure | Throws `MisuseError.fileUsedAfterClosing` |
| Using a shell agent after its `close()` | Assertion failure | Throws `MisuseError.shellAgentUsedAfterClosing` |

An operation already running when another task closes the client fails with the socket error the close caused, a
runtime error. Closing more than once is not a misuse, and neither is closing or releasing a file or shell agent after
its client closed: the client's `close()` released them. A shell agent whose command failed part way closes itself; its
later operations throw `ShellAgentError.channelClosedAfterFailure`, a runtime error. SwiftSFTP does not depend on a
logging library and logs nothing itself.

### Preconditions

These values stop the process in every build:

| Where | Value |
|------|------|
| `loginTimeOut`, `operationsTimeOut`, `getServerHostKey(timeOut:)`, `timeout`, `teardownGracePeriod` | Zero, negative, or NaN. `.infinity` means no timeout |
| `setKeepAlive(every:)` | Zero, negative, NaN, or infinite (`nil` disables keepalives) |
| Transfers | `bufferSize` or `chunkSize` below one; a local URL that is not a `file://` URL; a negative or non-finite `age` for `cleanupResumableUploads` or `cleanupResumableDownloads` |
| `SFTPSwarm` | A negative `numberOfForksToCreate`; an empty client list, a client listed twice, or a swarm inside a swarm; a count below one for `increaseClients` or `decreaseClients`, or one that would leave no connection; a `stripeSize` below one |
| `SwarmOptions`, auto-tune | A negative `tries`, or a negative or non-finite `delay`; a `clientCountLimit` below one or a negative `maximumBackAndForths` |
| `UserAuthentication` | An empty `.privateKeys([])` array |
| Shell agent | An empty input list (`tar`, `zip`, `sevenZip`, `concat`), a `compressionLevel` outside `0...9` |
| `ReferenceCache` and `InMemoryCacheStorage` configuration, `compareFiles` | Negative sizes and intervals, and the other out-of-range values their documentation names |

### SSH compression

Compression is disabled by default. Set `compressionPreference` on `SFTPClient.init` to request zlib
independently for each direction:

```swift
let client = try await SFTPClient(
    TCPLocation(hostname: "sftp.example.com", port: 22),
    authentication: UserAuthentication(name: "alice", auth: .password("s3cr3t")),
    compressionPreference: (clientToServer: [.zlib], serverToClient: [.zlib])
)
```

Arrays list algorithms from most to least preferred. An empty array means `[.none]`, and `.none` is appended when absent
to allow an uncompressed fallback.

Unsupported compression falls back to `.none`; configuration failures also continue without compression rather than
throwing. Check `client.compression.clientToServer` and `client.compression.serverToClient` for the
negotiated algorithms (`.zlib` or `.none`).

Currently, SwiftSFTP and libssh2 only support zlib, but other compression algorithms can be added in the future.

### Timeouts

Timeout rules differ by API:

| API | Valid values | How to disable timeout |
|-----|--------------|------------------------|
| `loginTimeOut` at init | Positive, or `.infinity` | Pass `.infinity` |
| `operationsTimeOut` at init | Positive, `nil`, or `.infinity` | Pass `nil` or `.infinity` (libssh2 default: no blocking-call timeout) |
| `getServerHostKey(..., timeOut:)` | Positive, or `.infinity` | Pass `.infinity` |
| `client.timeout` after construction | Positive, or `.infinity` | Set `client.timeout = .infinity` (maps to libssh2 `0`) |
| `client.teardownGracePeriod` | Positive, or `.infinity` (default `1.0`) | Set `client.teardownGracePeriod = .infinity` — the goodbye then runs under `operationsTimeOut` alone |

Zero, negative, and NaN timeouts stop the process everywhere (see [Preconditions](#preconditions)). Using the `timeout`
property after `close()` is a misuse: a debug build stops, and a release build reads zero or ignores the new value. Reading
`timeout` returns `.infinity` when libssh2 has no timeout configured.
`operationsTimeOut: .infinity` is normalized to the same internal state as `nil`.

### Forking a client

Use `fork()` when concurrent work needs another connection with the same configuration:

```swift
let worker = try await client.fork()
defer { try? await worker.close() }
```

The fork is logged in when it returns. It inherits the server location, operation and login timeouts, host-key
acceptance policy, authentication, compression preferences in both directions, teardown grace period, read-ahead,
write-ahead, and deinit error handler. It has an independent SSH session, socket, SFTP subsystem, identity, and
keepalive state.

To keep several connections open and share work between them, make an [`SFTPSwarm`](#swarms-of-connections) instead
of managing forks yourself.

### Closing the connection

Close explicitly when the outcome matters, and let the rest go; see [Closing and releasing](#closing-and-releasing):

```swift
try await fileHandle.close()  // the server confirmed the file is closed
try await client.close()      // the polite goodbye, now
```

The `closed` property is available on both if you need to check state.

---

## Authentication

Credentials are a `UserAuthentication` value: remote **username** plus a `UserAuthenticationMode`.
The initializer applies them after the SSH handshake.

| Mode | Use when |
|------|----------|
| `.password(_:)` | Password authentication |
| `.privateKey(_:)` | One private key (`PrivateKey`) |
| `.privateKeys(_:)` | Several private keys (`[PrivateKey]`) |

Empty usernames and empty passwords are rejected at client construction
(`.invalidUsername` / `.invalidPassword`).

Private keys are `PrivateKey` values, parsed, decrypted, and checked when you create them. A missing file, malformed
key, or wrong passphrase throws from the `PrivateKey` initializer, before any connection is made.

### Password

```swift
UserAuthentication(name: "alice", auth: .password("s3cr3t"))
```

### Private key from memory

```swift
let pem = """
-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEIGYjP7RxFRNEUJLgrI3JIbf0HusB+uh40DOCcvkw4KZY
-----END PRIVATE KEY-----
"""
let adaAuth = try UserAuthentication(name: "ada", auth: .privateKey(PrivateKey(string: pem)))
```

With a passphrase (encrypted PKCS#8):

```swift
let encPkcs8 = """
-----BEGIN ENCRYPTED PRIVATE KEY-----
MIGjMF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBCv7OFsFytpLehx/f7u
6otnAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQZoWkoTusUX1UPv+Q
l5660ARAQUnm6k8TrAhjqvfYutpenh8bn1TTs9ysjKRlEowQPf6Q1bmypow3NifQ
G5Wmq8A8p+PLsMwH0q36YeRuNcPG5w==
-----END ENCRYPTED PRIVATE KEY-----
"""
let brunaAuth = try UserAuthentication(
    name: "bruna",
    auth: .privateKey(PrivateKey(string: encPkcs8, passphrase: "nobodyknows"))
)
```

### Private key from a file

```swift
let chiaraPrivateKeyFile = URL(fileURLWithPath: "/users/chiara/.ssh/id_rsa")
let chiaraAuth = try UserAuthentication(
    name: "chiara",
    auth: .privateKey(PrivateKey(file: chiaraPrivateKeyFile))
)

let chiaraEncryptedPrivateKeyFile = URL(fileURLWithPath: "/users/chiara/MyKeys/id_rsa.enc")
let chiaraAuthEnc = try UserAuthentication(
    name: "chiara",
    auth: .privateKey(PrivateKey(file: chiaraEncryptedPrivateKeyFile, passphrase: "donttell"))
)
```

`PrivateKey(file:passphrase:)` reads OpenSSH, PEM, or PKCS#8 text; `PrivateKey(derFile:)` reads unencrypted DER. The
public key is derived from the private material; you do not need a separate `.pub` file.

### Several private keys

Pass every candidate yourself. SwiftSFTP does **not** scan `~/.ssh`, read `ssh_config`, or
use ssh-agent.

```swift
let files = ["/users/dina/.ssh/id_rsa", "/users/dina/.ssh/id_ecdsa"]
let keys = try files.map { try PrivateKey(file: URL(fileURLWithPath: $0)) }

let dinaAuth = UserAuthentication(name: "dina", auth: .privateKeys(keys))

// Keys from files and memory mix freely.
let newDinaAuth = try UserAuthentication(name: "dina", auth: .privateKeys(keys + [PrivateKey(string: pem)]))
```

### How multi-key selection works

On login with `.privateKey` or `.privateKeys`:

1. Classify each key (RSA, Ed25519, ECDSA P-256/384/521).
2. Use the server’s RFC 8308 `server-sig-algs` when available.
3. Prefer keys whose algorithms the server lists (and order by that preference); keys of the same algorithm keep the
   order of the array.
4. Try candidates until one authenticates or all fail.

`server-sig-algs` is about **signature algorithms the daemon supports**, not which public keys
are in `authorized_keys`. A compatible key can still be rejected if it is not authorized for
the username. An empty `.privateKeys([])` array stops the process.

### Supported key material

| | |
|--|--|
| **Formats** | PEM, PKCS#8, OpenSSH (`BEGIN OPENSSH PRIVATE KEY`), DER (`PrivateKey(derFile:)`) |
| **Algorithms** | RSA, ECDSA P-256 / P-384 / P-521, Ed25519 |

`PrivateKey` accepts any valid key, including types SSH cannot authenticate with (Ed448, ML-DSA, SLH-DSA, RSA under
1024 bits); the client initializer rejects those with `.invalidPrivateKey`. Check a key offline with
`SSHUserKeyAlgorithm(privateKey:)`, which is `nil` for them, or with `PrivateKey.validForSSHAuth` — see
[Validating SSH Keys (Offline)](#validating-ssh-keys-offline). Those checks do not prove server authorization.

> **Note:** SSH agent and keyboard-interactive authentication are not supported by `SFTPClient`.

---

## Host Key Verification

The server's host key is verified right after the SSH handshake, inside the initializer. If the key does not match
the configured acceptance settings, the initializer throws `HostKeyVerificationError.keyMismatch` (the host is known but
presented a different key — a possible man-in-the-middle) or `HostKeyVerificationError.unknownHostKey` (no entry for
the host).

### Accept any host key (development only)

```swift
hostKeyAcceptance: .acceptAny
```

> **Warning:** Never use `.acceptAny` in production. It makes your connection vulnerable to man-in-the-middle attacks.

### Pin against a known_hosts file

```swift
hostKeyAcceptance: .loadKnownHostsFile(URL(filePath: "/Users/alice/.ssh/known_hosts"))
```

### Pin against a known_hosts string you manage yourself

```swift
let knownHostsContent: String = // … loaded from secure storage
hostKeyAcceptance: .loadKnownHostsString(knownHostsContent)
```

### Obtaining a server's host key

Use the static helper before you establish a full connection. It returns a `known_hosts` line, ready for
`.loadKnownHostsString`:

```swift
let hostKeyLine = try await SFTPClient.getServerHostKey(
    TCPLocation(hostname: "sftp.example.com", port: 2222)
)
print(hostKeyLine)
// [sftp.example.com]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB...
```

Store the line securely and supply it via `.loadKnownHostsString(_:)` on subsequent connections. Several lines, one
per host, can share one string.

The host field is `TCPLocation.knownHostsFormat`: the bare host for port 22, `[host]:port` otherwise. To turn a key
stored without its host (`algorithm base64`, as SwiftSFTP 3 returned it) into a line, prefix it with that field:

```swift
let location = TCPLocation(hostname: "sftp.example.com", port: 2222)
hostKeyAcceptance: .loadKnownHostsString("\(location.knownHostsFormat) \(storedKey)")
```

---

## Navigating the Remote Filesystem

### Windows SFTP servers and path notation

SFTP always uses `/` as the path separator. On **OpenSSH for Windows**, a drive path is exposed as `/C:/Users/...`, not
`C:\Users\...`. Convert Windows notation with `String.sftpPathFromWindows` before calling the client:

```swift
let remote = #"C:\Users\alice\Documents\report.pdf"#.sftpPathFromWindows
// → "/C:/Users/alice/Documents/report.pdf"

try await client.upload(from: localURL, to: remote)
try await client.listDirectory(path: #"D:\data"#.sftpPathFromWindows) // → "/D:/data"
```

Relative Windows paths keep a relative shape (`#"docs\file.txt"#.sftpPathFromWindows` → `"docs/file.txt"`). Paths that
are already SFTP-style are only normalized. Drive letters are **not** rewritten automatically inside `SFTPClient`, so
ordinary Unix paths such as `/var/log` are never treated as Windows drives.

When unsure of the server layout, start from `currentWorkingDirectory` and list `"."`.

```swift
// Working directory
let cwd = try await client.currentWorkingDirectory

// List a directory (non-recursive)
let entries = try await client.listDirectory(path: "uploads") // (list the directory "uploads" under the current working directory)

// Recursive listing
let all: [FileMetadata] = try await client.listDirectory(path: "/data", recursive: true) // (list the directory "data" from the root)

// Useful subsets and sorted copies of [FileMetadata]
let files       = entries.regularFiles
let dirs        = entries.directories
let visible     = entries.nonHidden
let sorted      = entries.bySize
let dirFirst    = entries.directoriesFirst
```

`listDirectory` returns `[FileMetadata]` in the order the server lists the entries; with `recursive`, each
subdirectory's entries follow its own. It keeps every entry, including names that differ only in Unicode normalization
(`café` with a precomposed `é`, and with `e` plus a combining accent), which servers hold as different files while
`String` compares them as equal. Each entry exposes:

| Property | Type | Notes |
|----------|------|-------|
| `fileName` | `String` | Base name of the entry (e.g. `"report.txt"`) |
| `directory` | `String` | Parent directory path (e.g. `"/home/user/documents"`) |
| `fullPath` | `String` | Absolute remote path (joins `directory` and `fileName`) |
| `fileExtension` | `String?` | Last extension without the leading `.` (e.g. `"gz"` for `archive.tar.gz`) |
| `attributes` | `FileAttributes` | SFTP attributes: size, permissions, timestamps, uid/gid |
| `isRegularFile` | `Bool` | True if the entry is a regular file |
| `isDirectory` | `Bool` | True if the entry is a directory |
| `isSymLink` | `Bool` | True if the entry is a symbolic link |

### Stat a single path

```swift
let meta = try await client.stat(path: "/data/report.pdf", followLink: true)
let fileMeta = try await client.statFile(path: "/data/report.pdf", followLink: true)
let dirMeta  = try await client.statDirectory(path: "/data", followLink: false)
```

All stat methods return `FileMetadata?` — `nil` when the path does not exist.

### Calculate a directory's content size

```swift
do {
    let size = try await client.directorySize("/data/uploads")
    print("Directory contents: \(size) bytes")
} catch FileTransferErrors.remoteDirectoryNotFound(let path) {
    print("Directory not found: \(path)")
}
```

`directorySize(_:)` recursively traverses all subdirectories and returns the combined size of their regular files in
bytes. Empty directories return `0`. Symbolic links are neither followed nor included in the total. If the path does
not exist or is not a directory, the method throws `FileTransferErrors.remoteDirectoryNotFound(path:)`.

### Set attributes

Sets attributes on any remote path (file, directory, or symlink) using path-based `setstat`.

```swift
// Convenience — only non-nil parameters are sent
try await client.setAttributes(
    path: "/data/report.pdf",
    permissions: [.ownerRead, .ownerWrite, .groupRead]
)

// Low-level — build a FileAttributes value explicitly
var attrs = FileAttributes()
attrs.flags = .permissions
attrs.permissions = [.ownerRead, .ownerWrite, .groupRead]
try await client.setAttributes(path: "/data/report.pdf", attributes: attrs)
```

For an open file handle, use `file.set(_:)` or the convenience overload below.

### Check latency

```swift
let ping = try await client.latency    // TimeInterval; measures a CWD round-trip
```

### Server banner

```swift
let banner = try await client.banner
```

---

## Working with Files

Open a remote file with a set of `OpenFlags`:

```swift
let file = try await client.openFile([.read], path: "/data/report.pdf")

// Read up to N bytes from the current offset
if let chunk = try await file.read(upTo: 4096) {
    // process chunk
}

// Seek
file.offset = 8192

// Read all remaining content
let data = try await file.readAll()

// Close the handle
try await file.close()
```

### Open flags

| Flag | Meaning |
|------|---------|
| `.read` | Open for reading |
| `.write` | Open for writing |
| `.append` | Append writes to end of file |
| `.create` | Create the file if it does not exist |
| `.truncate` | Truncate to zero length on open |
| `.exclusive` | Fail if the file already exists (use with `.create`) |

### Writing

```swift
let handle = try await client.openFile([.write, .create, .exclusive], path: "/upload/new.txt")
let written = try await handle.write(Data("hello".utf8))
try await handle.fsync()    // flush to the remote server's disk (requires server support)
try await handle.close()
```

> **Chunk limit:** The SSH protocol transfers at most **32 KiB** per packet. Both the standard `read`/`write` methods and the convenience methods (see [Uploading and Downloading](#uploading-and-downloading)) handle chunking automatically.

### Read-ahead

Reads keep requests in flight ahead of the file position, so one connection is not limited to one request per round
trip. `client.readAhead` sets how many bytes: 2 MiB by default, the same as OpenSSH's `sftp`, and anything from 128 KiB
to 8 MiB. A read keeps at most four times its own size ahead, so ask for at least `readAhead / 4` bytes at a time to use
all of it.

```swift
client.readAhead = 8 * 1024 * 1024   // distant, fast server: keep libssh2's maximum in flight
let chunk = try await file.read(upTo: 1024 * 1024, readAheadLimit: rangeEnd)
```

What was requested ahead is still transferred after a seek, a cancelled read or a close, and then dropped. When you know
where your reads stop, pass that offset as `readAheadLimit`, as the transfer conveniences do. On links slower than about
`readAhead` per second, closing a handle right after cancelling its read can outlast `teardownGracePeriod`: lower
`readAhead` or raise `teardownGracePeriod`. Forks inherit the value.

### Write-ahead

Writes keep requests on their way to the server ahead of its acknowledgements, so an upload is not limited to one
32 KiB request per round trip. `client.writeAhead` sets how many bytes: 2 MiB by default, the same as OpenSSH's `sftp`,
and anything from 32 KiB to 8 MiB. The SSH channel window the server grants caps it as well; OpenSSH grants 2 MiB.

`write(_:)` still returns only once the server has acknowledged every byte, so each call ends with the pipeline empty.
Write several times `writeAhead` per call to keep the connection busy. The upload conveniences read 8 MiB per step by
default for that reason; at 30 ms of latency that is about 40 MB/s on one connection, where a 32 KiB write managed 1.

```swift
client.writeAhead = 8 * 1024 * 1024        // distant, fast server with a wider window than OpenSSH's
try await file.write(largeData)            // one call keeps the pipeline full until the last bytes
```

Requests already sent cannot be taken back: a cancelled write leaves up to `writeAhead` bytes on their way to the
remote file, so the remote size, not the handle's position, is where to resume. When the cancellation lands while the
socket is full, the write first finishes sending the packet libssh2 had started, for at most `teardownGracePeriod`,
because any other packet sent before it would corrupt the session. If the server takes nothing in that time, the client
keeps the packet and sends it before its next call that sends anything, within that call's own `operationsTimeOut` and
cancellation: calls fail with the timeout while the server still takes no data, and the connection carries on once it
does. Forks inherit the value.

### File attributes

```swift
// Read attributes
let attrs = try await file.stat

// Write attributes — only non-nil parameters are sent
try await file.set(
    permissions: [.ownerRead, .ownerWrite],
    date: (modification: Date(), access: Date()),
    owner: (uid: 1000, gid: 1000)
)

// Truncate
try await file.truncate(toSize: 0)
```

---

## Uploading and Downloading

`upload` and `download` move a whole file between the local filesystem and the server. They are requirements of
`SFTPClientProtocol`, so a swarm held as `any SFTPClientProtocol` still transfers as a swarm. An `SFTPClient` writes
the destination directly, over its one connection, as SwiftSFTP 3.24 did. An [`SFTPSwarm`](#swarms-of-connections)
does the same for small files, and sends larger ones in stripes over all of its connections, through a temporary file
it can resume; see [Transfers over a swarm](#transfers-over-a-swarm). The progress callback lets you report progress
or stop the transfer.

### Upload

```swift
let localFile = URL(filePath: "/Users/alice/Documents/archive.zip")

try await client.upload(
    from: localFile,
    to: "/home/alice/backups/archive.zip",
    bufferSize: 8 * 1024 * 1024    // the default; each step ends with one round trip, so keep it large
) { bytesTransferred, totalBytes, lastChunkBytes, lastChunkInterval in
    let percent = Double(bytesTransferred) * 100 / Double(totalBytes)
    let speed   = Double(lastChunkBytes) / lastChunkInterval    // bytes/sec
    print(String(format: "%.0f%%  %.1f KB/s", percent, speed / 1024))
    return true     // return false to stop
}
```

- Missing parent directories of the destination are created first, and are **not** removed again if the upload fails.
- With `resume: false`, the default, the destination must not exist: `FileTransferErrors.remoteFileAlreadyExists` is
  thrown if it does, and `.remotePathIsADirectory` if it is a directory. For `resume: true`, see
  [Resuming an interrupted transfer](#resuming-an-interrupted-transfer).
- `permissions` (the server's default when left out) are requested when the remote file is created.
- `bufferSize` is how much of the local file each step reads, 8 MiB by default. Each step's write returns only once the
  server has acknowledged all of it, so steps several times `writeAhead` keep the connection busy (see
  [Write-ahead](#write-ahead)).
- Overloads leave out any of `resume`, `bufferSize`, and `permissions`.

### Download

```swift
let destination = URL(filePath: "/tmp/archive.zip")

try await client.download(
    from: "/home/alice/backups/archive.zip",
    to: destination
) { bytesTransferred, totalBytes, lastChunkBytes, lastChunkInterval in
    return true
}
```

- The source must exist; symbolic links are followed. `FileTransferErrors.remoteFileNotFound` is thrown for a missing
  source, and on a swarm for one that is not a regular file; `.remotePathIsADirectory` is thrown for a directory.
- The destination's directory must exist. With `resume: false`, the default, the destination itself must not:
  `FileTransferErrors.localFileAlreadyExists` is thrown if it does.
- `bufferSize` is how much each step reads from the server, 512 KiB by default.
- Overloads leave out `resume`, `bufferSize`, or both.

### Resuming an interrupted transfer

A transfer that `SFTPClient` did not finish (cancelled, stopped by its callback, cut off by a dropped connection, or
killed with the process) leaves the destination holding what had arrived. Pass `resume: true` to continue it: when the
destination exists, its current size is the starting offset, and only the rest of the source is read and appended to
it. When the destination does not exist, `resume: true` changes nothing.

```swift
for attempt in 1 ... 3 {
    do {
        try await client.upload(from: localFile, to: "/home/alice/backups/archive.zip", resume: true) { _, _, _, _ in
            true
        }
        break
    } catch {
        guard attempt < 3 else { throw error }
        try await Task.sleep(nanoseconds: 5 * 1_000_000_000)
        // The next iteration appends what the destination is missing; it does not start over.
    }
}
```

Neither method calls itself again: a failure that ends the call is thrown. The same loop works on a swarm, which
continues its own way; see [Resuming a striped transfer](#resuming-a-striped-transfer).

> **Warning: resuming in place trusts the destination.** Its size is the only record of what arrived. Nothing checks
> that its bytes came from the same source, so resuming onto a file that holds something else, or after the source
> changed, appends to it and leaves a mixture of both. Where that matters, delete the destination and transfer again, or
> verify the result.

### Transfers over a swarm

An `SFTPSwarm` chooses how to move each file:

- A file of `smallFileThreshold` bytes or less, 10 MiB by default (`SFTPSwarm.defaultSmallFileThreshold`), moves **in
  place** over one connection, exactly as on an `SFTPClient`: no temporary file, and `resume: true` appends.
- A larger file whose destination already exists is continued in place over one connection when `resume` is `true`,
  as `SFTPClient` would continue it. With `resume: false`, the call throws `FileTransferErrors.remoteFileAlreadyExists`
  for an upload and `.localFileAlreadyExists` for a download, as on a client.
- Any other file goes **in stripes** of `stripeSize` bytes, 8 MiB by default (`SFTPSwarm.defaultStripeSize`), sent in
  order to whichever connection is free, so every connection of the swarm takes part. The stripes go into a temporary
  file beside the destination, which is renamed onto it once complete, so the destination appears only whole. An
  interrupted striped transfer can be [resumed](#resuming-a-striped-transfer) from that temporary file.

```swift
swarm.smallFileThreshold = 64 * 1024 * 1024   // stripe only files above 64 MiB
swarm.smallFileThreshold = 0                  // stripe every non-empty file
swarm.stripeSize = 16 * 1024 * 1024           // each connection moves 16 MiB at a time
```

`stripeSize` is the unit one connection moves at a time and the granularity of resuming: the stripes in flight when a
transfer is interrupted are sent again by the next call, so larger stripes repeat more. Values below one stop the
process. `bufferSize` keeps its meaning inside a stripe, the size of each read and write step, and each step's write
returns only once the server has acknowledged all of it, so steps several times `writeAhead` keep a connection busy.
Both properties belong to the swarm, not to its connections, and a swarm's `fork()` copies them.

#### Temporary files

The temporary file is named `<hash>.rmt.tmp`, where the hash is the first 128 bits of the SHA-256 of the destination's
file name, in uppercase Crockford Base32 (26 characters). It lives in the destination's own directory: on the server
for an upload, on disk for a download. The name depends only on the destination, so a retry finds the file an
interrupted attempt left, and a thousand failed attempts at one file leave one temporary file behind. A listing of the
directory during the transfer shows the temporary file instead of the destination.

The temporary file is preallocated and carries a trailer past the payload that records the destination's name, the
payload's size, the source's modification time, and how much of the payload has arrived. The trailer is cut off before
the rename, and the destination is checked again just before it. [Resumable trailer format](ResumableTrailerFormat.md)
describes its layout. `permissions` are requested when the temporary file is created; the rename keeps them.

An upload in stripes needs a server that shrinks a file with `SETSTAT`, to cut the trailer off. A server that refuses,
or accepts and does nothing, gets `FileTransferErrors.resumableTruncateUnsupported`: the file is not renamed into place,
and its temporary file is kept with the whole payload marked as arrived, so once the server is fixed the next upload
with `resume: true` finishes it without sending the payload again. A `smallFileThreshold` of `FileSize.max` moves every
file in place, as `SFTPClient` does, and needs no truncation, at the cost of resuming from a temporary file and of
spreading a transfer over the swarm. Transfers in place have no trailer and are not affected.

#### Resuming a striped transfer

A striped transfer that is interrupted (cancelled, stopped by its callback, cut off by a dropped connection, or killed
with the process) leaves its temporary file behind on purpose. The next call with the same source and destination and
`resume: true` sends only what is missing; with `resume: false`, it deletes the temporary file and starts over:

```swift
try await swarm.download(from: "/home/alice/backups/archive.zip", to: destination, resume: true) { _, _, _, _ in
    true    // continues the temporary file an interrupted download left, if any
}
```

A swarm sends a stripe that failed on a broken connection again on another connection, up to three times in all (see
[Broken connections](#broken-connections)); a failure that ends the call is thrown, as on a client.

A partial file is continued only when the destination name, the payload size, and the source's modification time
recorded in its trailer still match: the local file's modification time for an upload, the remote file's for a
download. Anything else is treated as another transfer's leftovers: the partial file is deleted and the transfer starts
from zero, without an error.

Stripes are handed out in order, so the holes an interruption leaves are near the end of the payload, and one number in
the trailer, the *valid prefix*, says how many bytes from the start can be trusted. It grows only once every stripe
before it is on the destination (acknowledged by the server for an upload, written to the local file for a download),
and it is written at most once a second. An interruption therefore costs sending again the stripes that were in flight,
plus, after an error or a crash, those finished since the last update. Progress starts where the partial file left off:
a transfer resumed at 80% reports about 80% on its first callback.

What happens to the temporary file:

| What happened | The temporary file |
|---------------|--------------------|
| A stop (the task was cancelled, or the callback returned `false`) | Kept, with the valid prefix written once more |
| An error: network, server, local I/O, short read or write | Kept, with the valid prefix as last written |
| A crash or kill | Kept, with the valid prefix as last written |
| A stop or an error while the valid prefix is still zero | Deleted: there is nothing to resume |
| The next call passes `resume: false` | Deleted by that call, which starts from zero |
| Trailer corrupt, or the source no longer matches | Deleted by the next call with `resume: true`, which starts from zero without an error |
| Trailer of a version this release does not read | Kept by a call with `resume: true`, which throws `FileTransferErrors.resumableTrailerVersionUnsupported` |
| Every byte arrived, but the server would not cut the trailer off | Kept with the whole payload marked valid; the call throws `FileTransferErrors.resumableTruncateUnsupported` |
| Transfer complete | Trailer cut off, then renamed onto the destination |

To start over on purpose, pass `resume: false`, or delete the temporary file: the `path` of
`resumableTrailerVersionUnsupported` names it, and the sweeps [below](#cleaning-up-abandoned-temporaries) remove those
left for too long.

> **Warning: two striped transfers to one destination at the same time corrupt each other unless SwiftSFTP sees both.**
> A second striped upload to a destination that one through the same swarm is writing, and a second striped download to
> a local file that one in the same process is writing, fail at once with
> `FileTransferErrors.transferAlreadyInProgress`. Transfers through other swarms, other processes, or other machines are
> not detected up front: they find the same temporary file and replace or interleave with each other's. An upload checks
> before publishing that the temporary file still holds its own transfer, and throws the same error when it does not,
> so it never publishes another transfer's bytes as its own; but the work of both is lost. Serialize those yourself,
> and transfers in place as well, which are not checked.

> **Warning: a source changed while keeping its size and modification time resumes as if unchanged.** Identity is name,
> size, and modification time, never a hash of the content. SFTP reports modification times in whole seconds, so a
> remote file replaced by another of the same size within the same second passes the check, and the resumed download
> mixes old content with new. Where that matters, pass `resume: false` or verify the result.

#### Cleaning up abandoned temporaries

```swift
// Remote: temporary files that striped uploads into this directory left behind
let sweptRemote: [String] = try await swarm.cleanupResumableUploads(
    in: "/home/alice/backups",
    olderThan: 7 * 24 * 60 * 60     // one week, in seconds
)

// Local: temporary files that striped downloads into this directory left behind
let sweptLocal: [URL] = try swarm.cleanupResumableDownloads(
    in: URL(filePath: "/Users/alice/Downloads"),
    olderThan: 7 * 24 * 60 * 60
)
```

Both list one directory without recursion, delete every regular file named like a striped transfer's temporary file (26
Crockford Base32 characters followed by `.rmt.tmp`) whose modification time is more than `age` seconds old, and return
what they deleted. A file listed without a modification time is left alone, since its age is unknown. A file that
cannot be deleted is skipped and the sweep goes on; only a failure to list the directory throws. `age` must be finite
and not negative. Both are available on any `SFTPClientProtocol`, a plain client included. `cleanupResumableDownloads`
uses no connection; it lives on the client only because `.rmt.tmp` is a SwiftSFTP convention rather than something
`FileManager` knows about.

> **Warning:** Neither method reads the trailers of the files it deletes, so neither can tell a transfer abandoned for
> good from one that another process is writing right now, which is why `age` has no default. A running transfer keeps
> its temporary file's modification time fresh; an interrupted one does not, and staying resumable for days is the
> point. Size `age` against how long you are willing to consider an interrupted transfer resumable, in hours or days,
> never against how long a transfer takes. Temporary files kept because their trailer is of another version are swept
> like any other once they are old enough. For the remote sweep, `age` is measured on the client's clock against
> modification times reported by the server's, so a server whose clock runs behind makes fresh temporary files look
> old enough to delete.

### Progress callback type

```swift
public typealias TransferProgress = (FileSize, FileSize, Int, TimeInterval) async -> Bool
// (bytesTransferred, totalBytes, lastChunkBytes, lastChunkInterval) — return false to stop
```

The callback is `async`, so it can `await` (for example hopping to a `@MainActor` to update UI). Synchronous closures
still compile unchanged. Returning `false` throws `FileTransferErrors.transferCancelled`.

A transfer in place, on an `SFTPClient` or a swarm, calls the callback inline and waits for it before moving the next
chunk, as in 3.24, so keep it short. So do the file handle methods, such as `write(from:)` and `read(to:)`.

A swarm's striped transfer calls it from a task of its own, one call at a time and in order, so no connection waits for
it while moving a stripe. `lastChunkBytes` is everything moved since the previous call, and `lastChunkInterval` the
seconds since that call. Between stripes, holding no connection, each connection waits for the callback to have seen
the bytes it moved. A slow callback therefore slows the transfer only at stripe boundaries, and a callback can run
operations on the same swarm, such as a `stat`, without stalling the transfer it reports on. Bytes sent again after a
broken connection count again, but `bytesTransferred` never exceeds `totalBytes`.

### Cancelling a transfer

There are two ways to stop a transfer, and they mean different things.

Returning `false` from the progress callback is a *cooperative stop*: the transfer stops before its next chunk, or, in
a swarm's striped transfer, within one stripe per connection; it unwinds cleanly and throws
`FileTransferErrors.transferCancelled`. It can only take effect between steps, so it cannot end a transfer whose server
has stopped sending data.

Cancelling the Swift task is a *hard stop* and works even then:

```swift
let transfer = Task {
    try await client.download(from: "/data/large.bin", to: localURL) { _, _, _, _ in true }
}

transfer.cancel()

do { try await transfer.value }
catch is CancellationError { /* the transfer stopped */ }
```

libssh2 has no way to interrupt a blocking call from another thread, so SwiftSFTP drives blocking reads and writes in
short slices (100 ms) on a dedicated queue and checks for cancellation between them. Cancellation is therefore observed
within roughly one slice rather than after `operationsTimeOut`, and blocking libssh2 calls never occupy a Swift
cooperative-pool thread. `read`, `write`, `fsync`, `stat`, and the upload/download conveniences all behave this way.

What a stopped transfer leaves behind:

| | |
|---|---|
| Transfers in place | The destination holds what arrived, and its size is the resume point for `resume: true`. A download flushes the chunks already received to the local file before the error surfaces; an upload's requests already sent still reach the remote file. |
| Striped transfers | The destination is untouched: it appears only with the final rename. The temporary file stays, with the valid prefix it reached written before the call returns, for a call with `resume: true` to continue; it is deleted when its valid prefix is still zero. See [Resuming a striped transfer](#resuming-a-striped-transfer). |
| Uploads | A write cut short with a packet half sent first finishes sending it, for at most `teardownGracePeriod`, and otherwise before the next call that sends. |
| The session | Untouched. If the server recovers, the connection is still usable. |

### Closing a connection that stopped responding

Closing is the other half of stopping. `close()` — on a handle or on the client — sends a goodbye that the peer has to
answer, and a peer that stopped answering reads and writes will not answer that either.

So the goodbye is best-effort: it gets a grace period — `client.teardownGracePeriod`, one second by default — and
then SwiftSFTP drops the socket regardless.
That is what actually makes the cleanup correct — once the descriptor is gone the server tears down its side of the
channel and the file handles opened on it. Once any call has given up waiting for the peer, later closes skip the
goodbye entirely and go straight to the drop.

Two properties fall out of this, both worth relying on:

- **Teardown is bounded by the grace period, not by `operationsTimeOut`.** Cancelling a stalled download and then
  closing the handle and the client returns in about a second, whether `operationsTimeOut` is 5 seconds or 30.
- **`client.close()` works while a transfer is still blocked inside libssh2.** It does not wait for that call; it shuts
  the socket down, which unblocks it with an error. You do not have to cancel first, though cancelling is tidier.

```swift
let handle = try await client.openFile(.read, path: "/data/large.bin", permissions: [])
let transfer = Task { try await handle.read(to: localURL) { _, _, _, _ in true } }

transfer.cancel()
_ = await transfer.result          // ~100 ms, even with the server silent

try? await handle.close()          // capped at the grace period
try? await client.close()          // skips the goodbye, drops the socket
```

`close()` throws only when releasing resources actually failed; a goodbye that timed out is logged, not thrown, because
everything was still freed.

Raise `teardownGracePeriod` for links slow enough that a legitimate goodbye needs longer than a second, or set it to
`.infinity` to switch the cap off and get the pre-cap behaviour back. Zero, negative, and NaN values stop the process. A client
from `fork()` inherits the current value.

```swift
client.teardownGracePeriod = 3           // satellite link: give the goodbye a fairer chance
client.teardownGracePeriod = .infinity   // no cap: bounded by operationsTimeOut alone
```

> With `.infinity`, `close()` goes back to waiting for a call that is still blocked inside libssh2 instead of dropping
> the socket to get past it. Together with `operationsTimeOut: nil` that means `close()` can block for as long as the
> peer stays silent.

> One known gap: libssh2 does not free a file handle whose `SSH_FXP_CLOSE` never completed, even when the session is
> shut down (there is a `TODO` to that effect in its `sftp_shutdown`). Abandoning handles on wedged connections
> therefore leaks a small amount of memory per handle until the process exits.

### Client-side remote copy

Copies a remote file to another remote path by routing the data through the client:

```swift
try await client.copyClientSide(
    from: "/data/source.dat",
    to: "/data/backup.dat",
    permissions: [.ownerRead, .ownerWrite]
) { _, _, _, _ in true }
```

For large files on the same host, prefer a [server-side copy](ShellAgent.md#server-side-copy) via the shell agent so
bytes never leave the server.

---

## Swarms of Connections

An `SFTPSwarm` is a set of SFTP connections to one server that stay open, used as one client. It conforms to
`SFTPClientProtocol`, so code written against the protocol works with a client or a swarm alike.

One connection's throughput is capped by the requests it keeps in flight: roughly `writeAhead` or `readAhead` divided by
the round-trip time. At the 2 MiB default that is about 67 MiB/s on a 30 ms link and 20 MiB/s on a 100 ms one, however
fast the link. More connections add windows, so they help where round trips are long, where the server limits a single
session, or where the link carries more than one window keeps busy. On a link that one connection already fills, they
add only handshakes; [auto-tune](#finding-the-best-number-of-connections) measures which case you are in.

### Creating a swarm

```swift
let client = try await SFTPClient(location, authentication: authentication)
let swarm = try await SFTPSwarm(client, numberOfForksToCreate: 3)   // four connections

try await swarm.upload(from: movie, to: "/Videos/holiday.mp4") { _, _, _, _ in true }
```

The swarm owns `client` from then on, and closes it with the others. Forks that fail to log in are retried as the
swarm's [options](#broken-connections) say; when one still fails, the forks already made are closed, `client` stays
yours and open, and the error is thrown. Forks are opened at most four at a time, because sshd drops connections beyond
its `MaxStartups` (10 by default) that have not logged in yet.

Two other initializers:

```swift
// From clients you already have: logged in, to the same server, each once.
let second = try await client.fork()
let swarm = try await SFTPSwarm([client, second])

// One new connection, with the parameters of SFTPClient's initializer. Add more with increaseClients(_:).
let swarm = try await SFTPSwarm(location, authentication: authentication)
```

An empty list, a client listed twice, or a swarm inside a swarm stops the process; a closed client is a misuse.

The settings `timeout`, `teardownGracePeriod`, `readAhead`, `writeAhead`, and the keepalive apply to every connection,
those that join later included. Setting one on the swarm returns at once: every connection gets the new value shortly
after the change, a busy one once its call in flight ends, and a connection that missed it, because it was leased in
between or joined later, takes it before its next operation. A new swarm takes them from its first client, except the keepalive, which you set with the swarm's own
`setKeepAlive` (see [Broken connections](#broken-connections)).

`smallFileThreshold` and `stripeSize` belong to the swarm itself rather than to its connections, and decide how it
transfers files; see [Transfers over a swarm](#transfers-over-a-swarm).

### Sharing out operations

Every operation, from a `stat` to one stripe of a transfer, goes to a connection no other operation is using. While
every connection is busy, operations wait their turn, first come first served. Uploads and downloads of files larger
than `smallFileThreshold` split the file into stripes of `stripeSize` bytes (see
[Transfers over a swarm](#transfers-over-a-swarm)) and send each to the next free connection, so one transfer uses
every connection, and a short operation waits for one stripe at most, never for a whole striped transfer.

```swift
// The three run at the same time, on different connections.
async let photos = swarm.listDirectory(path: "/Photos", recursive: false)
async let videos = swarm.listDirectory(path: "/Videos", recursive: false)
async let backup: Void = swarm.download(from: "/Backups/2026.tar", to: archive) { _, _, _, _ in true }
let (photoList, videoList, _) = try await (photos, videos, backup)
```

Operations started concurrently run in no particular order, as they would on separate clients: renaming a file while
deleting it does whatever the server does with the two. Operations awaited one after the other run in that order.

A striped transfer keeps as many stripes in flight as the swarm had working connections when it started. A transfer in
place, of a file of `smallFileThreshold` bytes or less or onto a destination that `resume: true` continues, holds one
connection from start to end, as it would on a client.

### File handles

A handle from `openFile` stays on the connection it was opened on, without reserving it: other operations still go to
that connection between the handle's own calls. The swarm opens a handle on the idle connection with the fewest open
handles, and does not close a connection while handles opened through it are open, except in `close()`.

### Broken connections

A connection that fails with a network or session error (a socket error, a timeout, a lost session or SFTP channel) is
taken out of the swarm and replaced by a fork of a working connection. The operation that hit it throws that error,
except in a striped transfer, which sends the stripe, or the step that sets the transfer up or finishes it, again on
another connection, up to three times in all. Every other operation throws, a transfer in place included. An SFTP
status such as a missing file or a refused permission, a local file error, and a cancellation leave the connection in
place.

`SwarmOptions.replaceBrokenConnections` says how a replacement is made: `tries` forks, `delay` seconds apart, the first
as soon as the connection breaks. The default is one try, with no delay. Zero tries leaves broken connections
unreplaced. A negative `tries`, or a negative or non-finite `delay`, stops the process.

```swift
let swarm = try await SFTPSwarm(
    client,
    numberOfForksToCreate: 3,
    options: SwarmOptions(replaceBrokenConnections: (tries: 5, delay: 2))
)
```

File handles on a broken connection keep failing until you close them. When every connection broke and none could be
replaced, operations throw `SwarmError.noConnections(lastError:)`. With replacement on, each operation that arrives then
starts one more round of replacement, so the swarm recovers once the server does.

`setKeepAlive` on a swarm configures every connection. A connection whose keepalive fails is taken out and replaced, and
then `onFailure` is called with the error.

### Growing and shrinking

```swift
let (healthy, setNumber) = await swarm.clientCount()
try await swarm.increaseClients(2)
try await swarm.decreaseClients(1)
```

`clientCount()` returns the connections taking work now and the number the swarm keeps. `healthy` is lower than
`setNumber` while a broken connection waits for its replacement, and after every attempt to replace it failed.

`increaseClients(_:)` forks new connections from a working one, each retried as `replaceBrokenConnections` says. It
keeps the connections it could make; when some could not be made, it throws the last error, and `setNumber` grows only
by the ones that joined.

`decreaseClients(_:)` removes connections, the least busy first. Idle ones close before it returns; one still running
an operation, or holding open file handles, takes no new work and closes once it is free. Both take a positive count,
and the swarm keeps at least one connection; other values stop the process.

### Finding the best number of connections

`autoTuneForUpload` and `autoTuneForDownload` measure rather than guess. Each round transfers a test file in stripes of
`stripeSize` bytes, whatever `smallFileThreshold` says, and times it:

```swift
let speeds = try await swarm.autoTuneForUpload(
    localFile: sample,                            // at least clientCountLimit × stripeSize
    testFilePath: "/home/alice/tune-probe.bin",   // must not exist yet
    clientCountLimit: 8,
    maximumBackAndForths: 2
)
for (count, bytesPerSecond) in speeds.sorted(by: { $0.key < $1.key }) {
    print("\(count) connection(s): \(bytesPerSecond / 1_048_576) MiB/s")
}
let (_, best) = await swarm.clientCount()       // the swarm is left at the fastest count
```

Starting at the swarm's current number of connections, or at `clientCountLimit` when that is lower, the search
measures one connection more for as long as that is faster. When one more is not faster, it measures the current number
again, since its first result may have been a fluke, and moves up after all if the repeat is slower; each such repeat
is a back and forth, and `maximumBackAndForths` caps how many the whole search makes. The search only adds connections:
it never goes below the starting count nor past `clientCountLimit`, and stops going up where the server refuses another
connection. To let it settle lower than the swarm is now, shrink the swarm with `decreaseClients(_:)` first.
The result holds bytes per second by number of connections, the last measurement of each, and the swarm is left at the
fastest.

For an upload, `testFilePath` must not exist (`FileTransferErrors.remoteFileAlreadyExists` otherwise). Each round
uploads `localFile` there and deletes it; missing parent directories are created and left. For a download,
`testFilePath` is the remote file every round downloads into a local temporary file:

```swift
let speeds = try await swarm.autoTuneForDownload(
    testFilePath: "/home/alice/tune-probe.bin",
    createTestFileIfDoesNotExist: (create: true, size: 256 * 1024 * 1024),
    clientCountLimit: 8,
    maximumBackAndForths: 2
)
```

With `create: true`, a missing test file is uploaded first, filled with random bytes, and deleted at the end. With
`create: false`, a missing one throws `FileTransferErrors.remoteFileNotFound`.

Use a test file of at least `clientCountLimit` stripes of `stripeSize` bytes (8 MiB each by default), ideally several
times that, or there is not enough work to share. Other operations running on the swarm meanwhile share its connections
and skew the measurements. Each round is a full transfer, so tune once per network and keep the result: a later swarm
starts at that count with `numberOfForksToCreate: best - 1`.

### Closing a swarm

```swift
try await swarm.close()
```

`close()` closes every connection, the busy ones included, and fails the operations waiting for one with
`SwarmError.closed`. File handles opened through the swarm close with their connections. It throws the first error of
closing a connection once all of them are closed, and calling it again is allowed. Using a swarm after `close()` is a
misuse, as for a client. A swarm released without `close()` releases its connections, which close themselves as
released clients do.

`fork()` on a swarm creates an independent swarm with as many connections, the same options, and the same settings,
`smallFileThreshold` and `stripeSize` included.

---

## Copying, Renaming, and Deleting

### Rename (POSIX)

```swift
try await client.rename(from: "/uploads/tmp_file", to: "/uploads/final_file")
```

### Rename with options

```swift
try await client.renameNonPosix(
    from: "/uploads/old.txt",
    to: "/uploads/new.txt",
    options: [.overwrite, .atomic]  // .native, .overwrite, .atomic
)
```

### Create a directory

```swift
try await client.createDirectory(
    path: "/uploads/2026/06",
    makePath: true,             // create intermediate directories
    mode: [.ownerRead, .ownerWrite, .ownerExecute]
)
```

### Delete

```swift
// Delete a single file
try await client.deleteFile(path: "/uploads/old.txt")

// Delete an empty directory
try await client.deleteDirectory(path: "/uploads/empty")

// Delete anything — recursively removes directories
try await client.delete(path: "/uploads/old_folder")
// No-op if the path does not exist
```

---

## Shell Agent (Server-Side Operations)

`SSHShellAgent` runs short commands over the same SSH session as your `SFTPClient`, using a persistent shell channel
rather than the SFTP subsystem. Copies, moves, archives, hashes, URL downloads, and nanosecond-resolution `stat` run on
the server, so the payload never crosses the network twice. Obtain one with `client.shellAgent()` and `close()` it when
you are done. The full API, supported shells, and requirements are covered in [Shell Agent](ShellAgent.md).

---

## Symlinks

```swift
// Resolve a symlink
let realPath = try await client.followLink(path: "/data/current")

// Create a symlink
try await client.createSymLink(path: "/data/current", destination: "/data/v3")
```

---

## Filesystem Statistics

Retrieve volume statistics for the filesystem the path resides on:

```swift
let vfs = try await client.filesystemStat(path: "/home/alice")
// FilesystemStat exposes: blockSize, fragmentSize, blocks, freeBlocks, availableBlocks,
// files, freeFiles, availableFiles, fileSystemID, flags, maximumNameLength
```

Also available on an open file handle:

```swift
let vfs = try await fileHandle.statFilesystem
```

---

## Keeping the Connection Alive

Enable periodic SSH keepalive messages after login by specifying the maximum idle interval in seconds:

```swift
try await client.setKeepAlive(every: 30)
```

Positive fractional intervals are rounded up to whole seconds. The minimum effective interval is two seconds. Passing
zero, a negative value, a non-finite value, or a value too large for libssh2 stops the process.

To be notified when a later keepalive send fails, provide an asynchronous callback:

```swift
try await client.setKeepAlive(every: 30) { error in
    print("The SFTP keepalive failed: \(error)")
    // Update connection state or schedule a reconnect here.
}
```

Enabling keepalive performs an immediate send check. An error from that check is thrown by `setKeepAlive`; after the
method returns, a send failure stops the keepalive loop and invokes the callback once. Disabling or reconfiguring
keepalive, or closing the client, does not invoke the callback.

Request a reply from the SSH server when required:

```swift
try await client.setKeepAlive(
    every: 30,
    requestsReply: true,
    onFailure: { error in
        print("The SFTP keepalive failed: \(error)")
    }
)
```

`requestsReply` sets the SSH `want-reply` flag. It does not turn `onFailure` into a reply acknowledgement or add a
reply timeout; the callback reports errors encountered while sending a periodic keepalive. If a connection failure is
encountered during an ordinary SFTP operation, that operation throws the error normally.

Calling the method again replaces the current keepalive configuration. Use `disableKeepAlive()` to stop it:

```swift
try await client.setKeepAlive(every: 60) // Reconfigure
try await client.disableKeepAlive()
```

The same methods are available through `SFTPClientProtocol`.

---

## Validating SSH Keys (Offline)

Parse your private key with `PrivateKey(string:passphrase:)` before connecting and read its `validForSSHAuth`, a
`Bool` that says whether the key is valid for SSH user authentication. Parsing throws when the key is malformed or
cannot be decrypted. Replace the sample key text below with your own.

For an **OpenSSH private key without a passphrase**, omit `passphrase`:

```swift
import SwiftSFTP

let openSSH = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCDEHKSMXe16whHqo6moq9GCYGzic4Z2vtGakChaf8NbAAAAKAA02KJANNi
iQAAAAtzc2gtZWQyNTUxOQAAACCDEHKSMXe16whHqo6moq9GCYGzic4Z2vtGakChaf8NbA
AAAECdOIB7s8sSZfEDF7SYJuSIkbBfhRaaDVwwJS2JUW34UoMQcpIxd7XrCEeqjqair0YJ
gbOJzhna+0ZqQKFp/w1sAAAAFm5lbHNvbkBOZWxzb24tTTQubG9jYWwBAgMEBQYH
-----END OPENSSH PRIVATE KEY-----
"""

print(try PrivateKey(string: openSSH).validForSSHAuth) // true
```

For a **PEM private key with a passphrase**, supply `passphrase` (this example uses encrypted PKCS#8):

```swift
import SwiftSFTP

let encryptedPEM = """
-----BEGIN ENCRYPTED PRIVATE KEY-----
MIGjMF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBDlGU/qgUbBY/pYLtlW
B1lkAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQTAGvU8+jnK3tfWd0
RfbqzQRA+/ABSfb97sHqcc0nZO1q4DG2eZEhgVppdpJ5lnhgqelnCLmF4X5mKrDR
jCJCXPEfKsl6qOLYvzfKn1+LBOj5jw==
-----END ENCRYPTED PRIVATE KEY-----
"""

print(try PrivateKey(string: encryptedPEM, passphrase: "testpassword123").validForSSHAuth) // true
```

An incorrect or missing passphrase makes `PrivateKey(string:passphrase:)` throw for the encrypted key.

Both checks run offline and do not verify that the key is authorized on a server.

For more formats, file-based validation, public keys, and algorithm checks, see
[Validating Existing Key Pairs](CryptographicUtils.md#validating-existing-key-pairs).

---

## Error Handling

### Configuration errors (`SFTPClientInvalidConfig`)

Thrown by `SFTPClient.preflightConfigurationCheck` and by `SFTPClient.init` before it connects:

| Case | Cause |
|------|-------|
| `.invalidHostname` | Hostname is empty or malformed |
| `.invalidPort` | Port is outside 1–65535 |
| `.invalidUsername` | Empty username |
| `.invalidPassword` | Empty password string |
| `.couldNotCreateSession(Error)` | libssh2 session allocation failed |
| `.invalidHostKeyFormat(Error)` | Malformed known_hosts file or string |
| `.invalidPrivateKey(Error)` | A private key of a type SSH cannot authenticate with |

### Authentication errors (`UserAuthenticationError`)

Thrown by `SFTPClient.init` after the handshake and host key verification, when the server does not accept the
configured authentication:

| Case | Cause |
|------|-------|
| `.rejected(Error)` | The server rejected the credentials; for several private keys, the last key's error |
| `.noKeyMatchesServerAlgorithms(serverAlgorithms:)` | No private key can produce a signature algorithm the server lists in `server-sig-algs`, so none was tried |

### Host key verification errors (`HostKeyVerificationError`)

Thrown by `SFTPClient.init` after the handshake when a host key acceptance other than `.acceptAny` is configured:

| Case | Cause |
|------|-------|
| `.keyMismatch` | Host is in the accepted keys but presented a different key (possible man-in-the-middle) |
| `.unknownHostKey` | Host has no entry in the accepted keys |

### Transfer errors (`FileTransferErrors`)

| Case | Cause |
|------|-------|
| `.transferCancelled` | Progress callback returned `false` |
| `.localFileNotFound` | Local source file missing, or a directory |
| `.localFileAlreadyExists(path:)` | Download destination already exists |
| `.shortWrite(expected:actual:)` | Server accepted fewer bytes than sent |
| `.shortRead(expected:actual:)` | Source file ended before a requested transfer range was read, for example a remote file that shrank during a download |
| `.remoteFileNotFound(path:)` | Remote source path does not exist or is not a regular file |
| `.remoteDirectoryNotFound(path:)` | Remote directory does not exist or the path is not a directory |
| `.remoteFileAlreadyExists(path:)` | Remote destination already exists |
| `.remotePathIsADirectory(path:)` | Expected file, found directory |
| `.remotePathIsAFile(path:)` | Expected directory, found file |
| `.resumableTrailerVersionUnsupported(version:path:)` | A swarm's striped upload or download, with `resume: true`, found a partial file whose trailer is of a version this release does not read, most likely written by another release of SwiftSFTP. The partial file at `path` is kept; pass `resume: false` or delete it to start over |
| `.resumableTruncateUnsupported(path:)` | A swarm's striped upload or download moved every byte, but the server, or for a download the local file system, refused to shrink the trailer away, so the rename was skipped. The partial file is kept with its whole payload marked valid, and once the server is fixed a later run with `resume: true` finishes it without sending the payload again. Transfers in place have no trailer and never throw it |
| `.resumableDestinationNameTooLong(byteCount:maximum:)` | The destination file name of a swarm's striped transfer is longer than the 4096 bytes a trailer can record; refused before anything is created |
| `.transferAlreadyInProgress(path:)` | Another striped transfer in this process is writing the same temporary file: an upload to the same destination through the same swarm, or a download to the same local file. A striped upload whose temporary file another swarm or process replaced throws it as it finishes. Transfers in place never throw it |

### Swarm errors (`SwarmError`)

Thrown by `SFTPSwarm` operations, besides the errors of the connection an operation ran on:

| Case | Cause |
|------|-------|
| `.closed` | The swarm was closed while the operation waited for a connection |
| `.noConnections(lastError:)` | Every connection broke and none could be replaced; `lastError` is the most recent failure, of a connection or of an attempt to replace one |

### Using a client after close

These are misuses, and so is using a swarm after its `close()`: a debug build stops, and a release build throws
`MisuseError`. See
[Errors, misuse, and impossible values](#errors-misuse-and-impossible-values).

### Shell agent errors (`ShellAgentError`)

Thrown by `shellAgent(shellType:)` and by `SSHShellAgent` operations:

| Case | Cause |
|------|-------|
| `.couldNotHeuristicallyDetectShellType` | Auto-detection could not identify a supported remote shell |
| `.hostDoesNotSupportOperation` | Requested hash algorithm (or equivalent) is unavailable on that shell family |
| `.commandFailed(exitCode:stdout:stderr:)` | Remote command exited non-zero |
| `.unexpectedOutput(String)` | Command output could not be parsed (for example a hash line) |
| `.invalidArgument(String)` | An empty path (to `stat`, or an archive or destination path), an empty download URL, or an unknown 7-Zip binary name |
| `.channelClosedAfterFailure` | An earlier command failed part way and the agent closed itself; open a new agent |

### libssh2 errors (`LibSSH2Error`)

Low-level errors surfaced from the C layer. Key cases:

- `.timeout` — operation exceeded the configured timeout
- `.authenticationFailed` — authentication rejected by server
- `.keyExchangeFailure` — SSH handshake failed (algorithm mismatch)
- `.sftp(status: LibSSH2SFTPStatus)` — SFTP protocol-level error (e.g. `.noSuchFile`, `.permissionDenied`, `.fileAlreadyExists`, `.operationUnsupported` for unsupported extensions such as `fsync` or `statvfs`)

### Typical `do/catch` pattern

```swift
do {
    try await client.upload(from: localURL, to: remotePath) { _, _, _, _ in true }
} catch FileTransferErrors.remoteFileAlreadyExists(let path) {
    // handle conflict
} catch let ShellAgentError.commandFailed(exitCode, stdout, stderr) {
    // remote shell command failed (server-side copy or hash)
    print("exit \(exitCode): \(stderr.isEmpty ? stdout : stderr)")
} catch let error as LibSSH2Error {
    // handle low-level SSH/SFTP error
    print(error.description)
} catch {
    throw error
}
```
