# SwiftSFTP — Engineer's Guide

This guide walks through everything you need to integrate and use SwiftSFTP in your application, from initial setup through advanced workflows.

## Table of Contents

1. [Connecting to a Server](#connecting-to-a-server)
2. [Authentication](#authentication)
3. [Host Key Verification](#host-key-verification)
4. [Navigating the Remote Filesystem](#navigating-the-remote-filesystem)
5. [Working with Files](#working-with-files)
6. [Uploading and Downloading](#uploading-and-downloading)
7. [Copying, Renaming, and Deleting](#copying-renaming-and-deleting)
8. [Symlinks](#symlinks)
9. [Filesystem Statistics](#filesystem-statistics)
10. [Validating SSH Keys (Offline)](#validating-ssh-keys-offline)
11. [Error Handling](#error-handling)
12. [Testability](#testability)

---

## Connecting to a Server

### Quick start — one call

```swift
import SwiftSFTP

let client = try await SFTPClient.initAndLogin(
    openSocketIn: TCPLocation(hostname: "sftp.example.com", port: 22),
    hostKeyAcceptance: .acceptAny,          // see Host Key Verification
    authentication: UserAuthentication(
        name: "alice",
        auth: .password("s3cr3t")
    )
)
defer { try? await client.close() }

// … your operations …
```

### Two-step (recommended when you want fine-grained control)

```swift
// Step 1: validate config and create session (no network I/O)
let client = try SFTPClient(
    openSocketIn: TCPLocation(hostname: "sftp.example.com", port: 22),
    operationsTimeOut: 30.0,    // applied to every libssh2 call after login; nil = libssh2 default
    hostKeyAcceptance: .acceptAny,
    authentication: UserAuthentication(
        name: "alice",
        auth: .privateKeyFile(file: URL(filePath: "/Users/alice/.ssh/id_ed25519"), password: nil)
    ),
    trapOnDeInitWithoutClose: true  // triggers SIGTRAP in debug if the client is deallocated without close()
)

// Step 2: connect (network I/O)
try await client.login(timeOut: 15.0)
```

### `TCPLocation`

```swift
TCPLocation(hostname: "sftp.example.com")           // port defaults to 22
TCPLocation(hostname: "192.168.1.10", port: 2222)
```

Accepts IPv4 addresses, IPv6 addresses, and DNS names. Port must be 1–65535.

### `initAndLogin` parameters summary

| Parameter | Type | Default | Notes |
|-----------|------|---------|-------|
| `openSocketIn` | `TCPLocation` | — | Server address |
| `operationsTimeOut` | `TimeInterval?` | `10.0` | Post-login timeout per operation; `nil` = libssh2 default |
| `loginTimeOut` | `TimeInterval` | `10.0` | Timeout for the login phase only |
| `hostKeyAcceptance` | `HostKeyAcceptance` | `.acceptAny` | See [Host Key Verification](#host-key-verification) |
| `authentication` | `UserAuthentication` | — | See [Authentication](#authentication) |
| `logger` | `Logger?` | `nil` | OSLog logger for close/deinit warnings |
| `trapOnDeInitWithoutClose` | `Bool` | `true` | `SIGTRAP` if deinit without `close()` (`SFTPClient.init` defaults to `false`) |

### Closing the connection

Always `close()` explicitly, both for the client and for any open file handles:

```swift
try await fileHandle.close()
try await client.close()
```

The `closed` property is available on both if you need to check state.

---

## Authentication

### Password

```swift
UserAuthentication(name: "alice", auth: .password("s3cr3t"))
```

### Private key from a file

```swift
UserAuthentication(
    name: "alice",
    auth: .privateKeyFile(
        file: URL(filePath: "/Users/alice/.ssh/id_rsa"),
        password: nil       // pass the passphrase if the key is encrypted
    )
)
```

### Private key from memory

```swift
let pemKey: String = // … loaded from Keychain or elsewhere
UserAuthentication(
    name: "alice",
    auth: .privateKeyString(keyData: pemKey, password: nil)
)
```

Supported key formats: PEM, PKCS#8, and OpenSSH (`BEGIN OPENSSH PRIVATE KEY`).  
Supported algorithms: RSA, ECDSA P-256 / P-384 / P-521, Ed25519.

> **Note:** SSH agent and keyboard-interactive authentication are not supported by `SFTPClient`.

---

## Host Key Verification

### Accept any host key (development only)

```swift
hostKeyAcceptance: .acceptAny
```

> **Warning:** Never use `.acceptAny` in production. It makes your connection vulnerable to man-in-the-middle attacks.

### Pin against a known_hosts file

```swift
hostKeyAcceptance: .loadFromFile(file: URL(filePath: "/Users/alice/.ssh/known_hosts"))
```

### Pin against a known_hosts string you manage yourself

```swift
let knownHostsContent: String = // … loaded from secure storage
hostKeyAcceptance: .loadFromFileString(file: knownHostsContent)
```

### Pin against explicit fingerprints

Accepts a `Set<String>` in `algorithm base64` form (same format returned by `getServerHostKey(shortHandForm: true)`):

```swift
hostKeyAcceptance: .shortHandAcceptedKeys([
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB...",
])
```

### Obtaining a server's fingerprint

Use the static helper before you establish a full connection:

```swift
let fingerprint = try await SFTPClient.getServerHostKey(
    openSocketIn: TCPLocation(hostname: "sftp.example.com"),
    shortHandForm: true     // "algorithm base64" — ready to paste into shortHandAcceptedKeys
)
print(fingerprint)
// ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB...
```

Store the fingerprint securely and supply it via `.shortHandAcceptedKeys` on subsequent connections.

---

## Navigating the Remote Filesystem

```swift
// Working directory
let cwd = try await client.currentWorkingDirectory

// List a directory (non-recursive)
let entries = try await client.listDirectory(path: "uploads") // (list the directory "uploads" under the current working directory)

// Recursive listing
let all: Set<FileMetadata> = try await client.listDirectory(path: "/data", recursive: true) // (list the directory "data" from the root)

// Useful subsets and conversions to array on Set<FileMetadata>
let files       = entries.regularFiles
let dirs        = entries.directories
let visible     = entries.nonHidden
let sorted      = entries.bySize
let dirFirst    = entries.directoriesFirst
```

`listDirectory` returns `Set<FileMetadata>`. Each entry exposes:

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

### File attributes

```swift
// Read attributes
let attrs = try await file.stat

// Write attributes
try await file.set(
    fileSize: nil,
    permissions: [.ownerRead, .ownerWrite],
    accessTime: Date(),
    modificationTime: Date(),
    userID: 1000,
    groupID: 1000
)

// Truncate
try await file.truncate(toSize: 0)
```

---

## Uploading and Downloading

Both methods handle chunking and directory creation automatically. The progress callback lets you report progress or cancel the transfer.

### Upload

```swift
let localFile = URL(filePath: "/Users/alice/Documents/archive.zip")

try await client.upload(
    from: localFile,
    to: "/home/alice/backups/archive.zip",
    bufferSize: 512 * 1024
) { bytesTransferred, totalBytes, lastChunkBytes, lastChunkInterval in
    let percent = Double(bytesTransferred) * 100 / Double(totalBytes)
    let speed   = Double(lastChunkBytes) / lastChunkInterval    // bytes/sec
    print(String(format: "%.0f%%  %.1f KB/s", percent, speed / 1024))
    return true     // return false to cancel
}
```

- The destination's parent directories are created automatically.
- The remote file must not already exist (uses `.exclusive`). If it does, `FileTransferErrors.remoteFileAlreadyExists` is thrown.

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

- The local file must not already exist. If it does, `FileTransferErrors.localFileAlreadyExists` is thrown.

### Progress callback type

```swift
public typealias TransferProgress = (Int64, Int64, Int, TimeInterval) -> Bool
// (bytesTransferred, totalBytes, lastChunkBytes, lastChunkInterval) — return false to cancel
```

Returning `false` throws `FileTransferErrors.transferCancelled`.

### Client-side remote copy

Copies a remote file to another remote path by routing the data through the client:

```swift
try await client.copyClientSide(
    from: "/data/source.dat",
    to: "/data/backup.dat",
    permissions: [.ownerRead, .ownerWrite]
) { _, _, _, _ in true }
```

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

## Validating SSH Keys (Offline)

`String` conforms to `KeyValidation`, allowing you to check whether a PEM, PKCS#8 or OpenSSH key string is valid before using it for user authentication:

```swift
let pem: String = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIGU49N3pXnY7QLxXGEf9vFayuBzcGp4knY1aFQbVgfeCoAoGCCqGSM49
    AwEHoUQDQgAEMSzxTnxAxZ8MxL9AXDScmv1pcWOXh8N3QYo4O+dvBVeFsaumKxit
    t3f3yxw97qIw5d+uUvDo1+1S7tcYRkWfIA==
    -----END EC PRIVATE KEY-----
    """

// Generic check — works for any supported algorithm
if pem.isValid_PrivateKey {
    // safe to use
}

// Encrypted key — validate with passphrase
if pem.isValid_PrivateKey(password: "passphrase") {
    // decryptable private key
}

// Algorithm-specific checks
pem.isValid_RSA_PrivateKey
pem.isValid_P256_PrivateKey
pem.isValid_P384_PrivateKey
pem.isValid_P521_PrivateKey
pem.isValid_Curve25519_PrivateKey   // Ed25519 / OpenSSH "BEGIN OPENSSH PRIVATE KEY" format
```

Equivalent `_PublicKey` variants are available for all algorithms (including `isValid_Curve25519_PublicKey`).

> This validates key format and parseability only. It does not verify that the key is authorized on any particular server.

---

## Error Handling

### Configuration errors (`SFTPClientInvalidConfig`)

Thrown synchronously from `SFTPClient.init` (including when called by `initAndLogin`), except where noted:

| Case | Cause |
|------|-------|
| `.invalidHostname` | Hostname is empty or malformed |
| `.invalidPort` | Port is outside 1–65535 |
| `.invalidTimeOutValue` | Timeout is negative, zero, or infinite |
| `.invalidUsername` | Empty username |
| `.invalidPassword` | Empty password string |
| `.couldNotCreateSession(Error)` | libssh2 session allocation failed |
| `.invalidHostKeyFormat(Error)` | Malformed known_hosts file or string |
| `.invalidPrivateKey(Error)` | Private key file missing at init time |
| `.authenticationFailed(Error)` | Server rejected credentials during `login()` |

### Transfer errors (`FileTransferErrors`)

| Case | Cause |
|------|-------|
| `.transferCancelled` | Progress callback returned `false` |
| `.notAFileURL` | Local URL is not a `file://` URL |
| `.localFileNotFound` | Local source file missing |
| `.localFileAlreadyExists(path:)` | Download destination already exists |
| `.invalidBufferSize` | `bufferSize` ≤ 0 |
| `.shortWrite(expected:actual:)` | Server accepted fewer bytes than sent |
| `.remoteFileNotFound(path:)` | Remote source path does not exist |
| `.remoteFileAlreadyExists(path:)` | Remote destination already exists |
| `.remotePathIsADirectory(path:)` | Expected file, found directory |
| `.remotePathIsAFile(path:)` | Expected directory, found file |

### State errors

| Type | Cause |
|------|-------|
| `AlreadyClosed` | Operation called on a closed client or file handle |
| `NotLoggedIn` | Operation called before `login()` |

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
} catch let error as LibSSH2Error {
    // handle low-level SSH/SFTP error
    print(error.description)
} catch {
    throw error
}
```

---

## Testability

`SFTPClient` and `SFTPFile` conform to `SFTPClientProtocol` and `SFTPFileProtocol` respectively. Inject these protocols into your own types and stub them in unit tests without needing a real server:

```swift
// Your service
struct BackupService {
    let sftp: any SFTPClientProtocol

    func backup(localURL: URL, remotePath: String) async throws {
        try await sftp.upload(from: localURL, to: remotePath) { _, _, _, _ in true }
    }
}

// In tests
struct MockSFTPClient: SFTPClientProtocol {
    // … implement only the methods your tests exercise
}

let service = BackupService(sftp: MockSFTPClient())
```

For integration tests against a real server, see `TestServerInfo.md` and start the Docker test server with `Scripts/test-server-up.sh`.
