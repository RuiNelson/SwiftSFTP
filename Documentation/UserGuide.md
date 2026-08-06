# SwiftSFTP — User's Guide

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
10. [Keeping the Connection Alive](#keeping-the-connection-alive)
11. [Validating SSH Keys (Offline)](#validating-ssh-keys-offline)
12. [Error Handling](#error-handling)
13. [Testability](#testability)

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
| `logger` | `Logger?` | `nil` | swift-log logger for close/deinit warnings |
| `trapOnDeInitWithoutClose` | `Bool` | `true` | `SIGTRAP` if deinit without `close()` (`SFTPClient.init` defaults to `false`) |

### Forking a client

Use `fork(loggedIn:)` when concurrent work needs another connection with the same configuration:

```swift
let worker = try await client.fork(loggedIn: true)
defer { try? await worker.close() }
```

The fork inherits the server location, operation timeout, most recently configured login timeout, host-key acceptance
policy, authentication, logger, and deinitialization behavior. It has an independent SSH session, socket, SFTP
subsystem, identity, and keepalive state. Pass `false` to create the configured client without connecting it.

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

The server's host key is verified right after the SSH handshake inside `login(timeOut:)`. If the key does not match
the configured acceptance settings, login throws `HostKeyVerificationError.keyMismatch` (the host is known but
presented a different key — a possible man-in-the-middle) or `HostKeyVerificationError.unknownHostKey` (no entry for
the host).

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

### Parallel transfers

Use `multiUpload` and `multiDownload` to split a file into byte ranges and transfer those ranges concurrently over
independent SSH/SFTP connections:

```swift
try await client.multiUpload(
    from: localFile,
    to: "/home/alice/backups/archive.zip",
    workers: 4,
    bufferSize: 1024 * 1024
) { bytesTransferred, totalBytes, lastChunkBytes, lastChunkInterval in
    return true
}

try await client.multiDownload(
    from: "/home/alice/backups/archive.zip",
    to: destination,
    workers: 4
) { _, _, _, _ in true }
```

`workers` is the maximum total number of connections, including the client on which the method is called. Additional
connections are created with `fork(loggedIn: true)`. Forks are attempted sequentially; if any additional fork cannot
log in, no more forks are attempted and the transfer continues silently with the workers already connected. This
allows servers with lower per-user or global connection limits to reduce parallelism without failing the transfer.

Both methods preallocate the destination and report aggregate, serialized progress for the complete file. Neither can
be resumed: an interrupted transfer starts over from the beginning, and neither leaves anything behind to continue
from. `multiUpload` writes to a uniquely named temporary file in the destination directory and atomically renames it
only after every range succeeds; failure or cancellation triggers a best-effort removal of that temporary file.
`multiDownload` removes its incomplete local destination after failure or cancellation.

To continue an interrupted multi-worker transfer instead of restarting it, use
[Resumable parallel transfers](#resumable-parallel-transfers) below.

### Resumable parallel transfers

`multiUploadResumable` and `multiDownloadResumable` transfer exactly like the two methods above, with one difference:
an interrupted transfer can be continued rather than restarted.

```swift
try await client.multiUploadResumable(
    from: localFile,
    to: "/home/alice/backups/archive.zip",
    workers: 4,
    bufferSize: 1024 * 1024
) { bytesTransferred, totalBytes, lastChunkBytes, lastChunkInterval in
    let percent = Double(bytesTransferred) * 100 / Double(totalBytes)
    print(String(format: "%.0f%%", percent))
    return true     // return false to cancel; the progress made so far is kept
}

try await client.multiDownloadResumable(
    from: "/home/alice/backups/archive.zip",
    to: destination,
    workers: 4
) { _, _, _, _ in true }
```

Resuming is not a mode or a session — it is the same call, made again. A dropped connection surfaces as a thrown
error like any other, and the next call with the same source and destination transfers only the blocks that are
missing:

```swift
for attempt in 1 ... 3 {
    do {
        try await client.multiUploadResumable(
            from: localFile,
            to: "/home/alice/backups/archive.zip",
            workers: 4
        ) { _, _, _, _ in true }
        break
    } catch {
        guard attempt < 3 else { throw error }
        try await Task.sleep(nanoseconds: 5 * 1_000_000_000)
        // The next iteration picks up where this one stopped; it does not start over.
    }
}
```

Neither method retries or reconnects on its own, and neither waits: a failure ends the call.

#### How the progress is remembered

The bytes go into a temporary file in the destination's own directory, named `<hash>.rmt.tmp`, where the hash is the
first 128 bits of the SHA-256 of the destination's file name, in Base32 Crockford (26 characters). Past the end of the payload — starting at the byte the
finished file will end at — the same file carries a trailer holding the final file name, the payload size, the
source's modification time, and a bitmap with one bit per block. There is no database and no separate state file:
everything a resume needs is inside the file it is resuming, and because the temporary's name is derived from the
destination's name, the next call finds its own partial without being told where it is.

When the last block arrives, the trailer is truncated away, the truncation is verified with a `stat`, and only then is
the file renamed onto the destination — which therefore never exists in a partial state. `multiDownloadResumable` is
atomic in this way too, unlike `multiDownload`, which writes to `localURL` directly.

Blocks are sized automatically from the payload size and the requested worker count: 10 MiB at most, and larger only
above roughly 2.5 TiB, where the bitmap has to stay within a single 32 KiB write. Block size is not configurable, and
on a resume the size recorded in the trailer wins over any later change to `workers`, since recomputing it would
invalidate the bitmap already in the file. Within a block the transfer still moves `bufferSize` bytes at a time.

A block's bit is set only after that block's last write has been acknowledged by the destination, and the bitmap is
written back every two seconds rather than after every block. The record of what has arrived therefore always lags the
data and never leads it. An interruption costs re-transferring the blocks that were in flight, plus — after a crash or
a kill, which cannot flush — those completed since the last bitmap write. Bits only ever go from 0 to 1, so even a
bitmap write cut in half by a crash leaves a valid, pessimistic map.

#### What survives an interruption, and what does not

| What happened | The temporary file |
|---------------|--------------------|
| Cancellation (`Task` cancelled, or the callback returned `false`) with at least one block complete | Preserved, with a final bitmap write |
| Error thrown (network, server, local I/O, short write) with at least one block complete | Preserved, with a final bitmap write |
| Cancellation or error with not a single block complete | Deleted — there is nothing to resume |
| Crash or kill | Preserved, with the bitmap as of the last write |
| Trailer corrupt, or the source no longer matches | Deleted; the transfer restarts from zero, without an error |
| Trailer written by a newer release of SwiftSFTP | Preserved; `resumableTrailerVersionUnsupported` is thrown |
| Every byte moved, but the server refused to truncate the trailer away | Preserved with every block marked done; `resumableTruncateUnsupported` is thrown, and a later run finishes it without re-transferring anything |
| Transfer completed | Truncated and renamed onto the destination |

A partial file is adopted only when the file name, payload size, and source modification time recorded in its trailer
all match the source as it is now (modification times compare at whole-second resolution, which is what SFTP stores).
Anything else is treated as another transfer's leftovers: the file is deleted and the transfer starts at zero,
silently. Because the temporary's name is deterministic, a thousand failed attempts at the same file leave one
temporary file, not a thousand.

`doNotResume: true` deletes any existing temporary file before it is even read. It is both the clean-slate switch and
the only way past a partial file written by a newer release of the library:

```swift
try await client.multiUploadResumable(
    from: localFile,
    to: "/home/alice/backups/archive.zip",
    workers: 4,
    doNotResume: true       // discard any partial file without reading it, and start from zero
) { _, _, _, _ in true }
```

#### What is not protected

> **Warning: two concurrent transfers to the same destination corrupt each other.** Two processes, two machines, or
> two calls inside one process transferring to the same destination derive the same temporary file name and interleave
> their blocks into it. The file that eventually gets published is a mixture of both, and neither call notices.
> Nothing in the library prevents this — no lock file, no ownership marker — so serialize such transfers yourself.
> This is a known gap, to be addressed in a later version.

> **Warning: a source changed while keeping both its size and its modification time resumes as if unchanged.**
> Identity is name, size, and mtime, never a hash of the content. A file restored by a tool that preserves timestamps,
> or rewritten in place within the same second at the same length, passes the check, and the published file is part
> old content and part new. Closing that window would mean reading every byte of the source before transferring any of
> it. Where it matters, pass `doNotResume: true` or verify the result yourself.

A network failure is an error, not a pause: the call throws, the partial file is preserved as long as at least one
block completed, and resuming means calling the method again.

One case remains where the bitmap can be optimistic: a server that acknowledges writes and then loses them, by
crashing with data still in its cache. The library cannot detect it. A single `fsync` is issued before the final
truncation, and its failure is ignored, because not every server implements the extension.

#### Connections, workers, and progress

`workers` counts the client the method is called on plus its forks, exactly as in `multiUpload`/`multiDownload`, and
forks that cannot log in reduce parallelism silently. An upload opens **one connection more** than `workers`: the extra
one writes the bitmap, so that a trailer write never queues behind a megabyte of payload (if that fork fails too, the
bitmap goes over the calling client's own connection). A download opens exactly `workers`, since its trailer is written
locally, where it competes with nothing. On a resume, the effective worker count is capped at the number of blocks
still missing.

Progress starts where the partial file left off rather than at zero: `bytesTransferred` opens at the bytes the
temporary file already holds, and `totalBytes` is the payload's size, with the trailer excluded. A transfer resumed at
80% therefore reports about 80% on its first callback, not 0%.

The destination is checked for existence before the partial file is even looked for, so an upload onto a path that
already exists throws `FileTransferErrors.remoteFileAlreadyExists` (and a download,
`FileTransferErrors.localFileAlreadyExists`) before a byte moves. It is checked once more immediately before the
rename, because a transfer takes long enough for the answer to change. As with `upload`, an upload's missing remote
parent directories are created first, and they are **not** removed again if the transfer then fails.

#### Cleaning up abandoned temporaries

```swift
// Remote: temporaries left behind by multiUploadResumable
let sweptRemote: [String] = try await client.cleanupResumableUploads(
    in: "/home/alice/backups",
    olderThan: 7 * 24 * 60 * 60     // one week, in seconds
)

// Local: temporaries left behind by multiDownloadResumable
let sweptLocal: [URL] = try client.cleanupResumableDownloads(
    in: URL(filePath: "/Users/alice/Downloads"),
    olderThan: 7 * 24 * 60 * 60
)
```

Both list one directory without recursion, delete every regular file whose name ends in `.rmt.tmp` and whose
modification time is older than `age` seconds ago, and return what actually went away — sorted, and not the same thing
as what matched, since a file that cannot be deleted is skipped rather than allowed to abort the sweep. A missing or
unreadable directory throws, so that a mistyped path cannot pass for a clean one; use `try?` if that distinction is
not worth making. An entry whose modification time cannot be read — one the server listed without a timestamp, for
instance — is never swept, since there is then no evidence of abandonment. `cleanupResumableDownloads` uses no
connection and works on a closed client; it lives on the client only because `.rmt.tmp` is a SwiftSFTP convention
rather than something `FileManager` knows about.

> **Warning:** This is the only operation in the feature that destroys resumable progress irreversibly. Neither method
> reads the trailers of the files it deletes, so neither can tell a transfer abandoned for good from one that another
> process is writing to at this very moment — which is why `age` has no default value. Size `age` against how long you
> are willing to consider an interrupted transfer resumable, in hours or days, and never against how long a transfer
> takes: a paused transfer's modification time does not advance, and remaining resumable for days is the point of the
> feature. Two further consequences of not reading the trailer: a temporary preserved because it came from a newer
> release of the library is swept like any other once it is old enough, and, for the remote sweep, `age` is measured
> on the client's clock against modification times reported by the server's, so a server running behind makes fresh
> temporaries look old enough to delete.

### Choosing a worker count

The best number of workers depends on the link and on the server, so `multiTune` measures it instead of guessing. It
transfers a test file once per worker count, starting at `workersStart` and growing by `workersStep`, and stops at the
first round that is not faster than the best round so far:

```swift
let workers = try await client.multiTune(
    testDirection: .upload,
    workersMax: 8,
    testFilePath: "/home/alice/tune-probe.bin",
    testFileSize: 10 * 1024 * 1024,
    bestOf: 3,
    logger: logger
)

try await client.multiUpload(from: localFile, to: remotePath, workers: workers) { _, _, _, _ in true }
```

For `.upload`, a local temporary file of `testFileSize` random bytes is created and uploaded to `testFilePath`, which
is deleted from the server after every round; any parent directories the upload had to create are **not** removed
again. For `.download`, `testFilePath` must already be a remote regular file, `testFileSize` is ignored, and each
round downloads to a local temporary file that is removed afterwards.

Because a single timed transfer is sensitive to whatever else the link is carrying, `bestOf` repeats the whole search
and keeps the worker count from the fastest search. The optional `logger` reports each round's duration and
throughput, each search's pick, and the final result at `info` level. The search is cooperatively cancellable between
searches, between rounds, and inside each transfer.

Tuning costs `bestOf` × (rounds) full transfers of the test file, so run it once per network and cache the result
rather than before every transfer.

### Progress callback type

```swift
public typealias TransferProgress = (Int64, Int64, Int, TimeInterval) async -> Bool
// (bytesTransferred, totalBytes, lastChunkBytes, lastChunkInterval) — return false to cancel
```

The callback is `async`, so it can `await` (for example hopping to a `@MainActor` to update UI) without blocking. The
transfer waits for it before sending the next chunk, so keep it short. Synchronous closures still compile unchanged.

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

## Keeping the Connection Alive

Enable periodic SSH keepalive messages after login by specifying the maximum idle interval in seconds:

```swift
try await client.setKeepAlive(every: 30)
```

Positive fractional intervals are rounded up to whole seconds. The minimum effective interval is two seconds. Passing
zero, a negative value, a non-finite value, or a value too large for libssh2 throws
`SFTPClientInvalidConfig.invalidKeepAliveInterval`.

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

### Host key verification errors (`HostKeyVerificationError`)

Thrown from `login()` after the handshake when a host key acceptance other than `.acceptAny` is configured:

| Case | Cause |
|------|-------|
| `.keyMismatch` | Host is in the accepted keys but presented a different key (possible man-in-the-middle) |
| `.unknownHostKey` | Host has no entry in the accepted keys |

### Transfer errors (`FileTransferErrors`)

| Case | Cause |
|------|-------|
| `.transferCancelled` | Progress callback returned `false` |
| `.notAFileURL` | Local URL is not a `file://` URL |
| `.localFileNotFound` | Local source file missing |
| `.localFileAlreadyExists(path:)` | Download destination already exists |
| `.invalidBufferSize` | `bufferSize` ≤ 0 |
| `.shortWrite(expected:actual:)` | Server accepted fewer bytes than sent |
| `.shortRead(expected:actual:)` | Source file ended before a requested transfer range was read |
| `.remoteFileNotFound(path:)` | Remote source path does not exist |
| `.remoteDirectoryNotFound(path:)` | Remote directory does not exist or the path is not a directory |
| `.remoteFileAlreadyExists(path:)` | Remote destination already exists |
| `.remotePathIsADirectory(path:)` | Expected file, found directory |
| `.remotePathIsAFile(path:)` | Expected directory, found file |
| `.resumableTrailerVersionUnsupported(version:path:)` | A resumable transfer found a partial file written by a newer release of SwiftSFTP. The partial file is preserved, not deleted; `doNotResume: true` discards it and starts over |
| `.resumableTruncateUnsupported(path:)` | Every byte arrived, but the server refused to shrink the trailer away, so the rename was skipped. The partial file is preserved with every block marked done, and a later run finishes it without re-transferring anything |
| `.resumableDestinationNameTooLong(byteCount:maximum:)` | Destination file name is longer than the 4096 bytes a trailer can record; refused before anything is created |

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
