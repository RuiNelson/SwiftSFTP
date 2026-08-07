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
8. [Shell Agent (Server-Side Operations)](#shell-agent-server-side-operations)
9. [Symlinks](#symlinks)
10. [Filesystem Statistics](#filesystem-statistics)
11. [Keeping the Connection Alive](#keeping-the-connection-alive)
12. [Validating SSH Keys (Offline)](#validating-ssh-keys-offline)
13. [Error Handling](#error-handling)

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
    operationsTimeOut: 30.0,    // applied to every libssh2 call after login; nil or .infinity = no timeout
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
| `operationsTimeOut` | `TimeInterval?` | `10.0` | Post-login timeout per operation; must be positive when set. Pass `nil` or `.infinity` for no blocking timeout (libssh2 default) |
| `loginTimeOut` | `TimeInterval` | `10.0` | Timeout for the login phase only; must be positive and finite (`.infinity` is rejected) |
| `hostKeyAcceptance` | `HostKeyAcceptance` | `.acceptAny` | See [Host Key Verification](#host-key-verification) |
| `authentication` | `UserAuthentication` | — | See [Authentication](#authentication) |
| `logger` | `Logger?` | `nil` | swift-log logger for close/deinit warnings |
| `trapOnDeInitWithoutClose` | `Bool` | `true` | `SIGTRAP` if deinit without `close()` (`SFTPClient.init` defaults to `false`) |

### Timeouts

Timeout rules differ by API:

| API | Valid values | How to disable timeout |
|-----|--------------|------------------------|
| `operationsTimeOut` at init / `initAndLogin` | Positive finite, `nil`, or `.infinity` | Pass `nil` or `.infinity` (libssh2 default: no blocking-call timeout). Negative, zero, and NaN throw `.invalidTimeOutValue` |
| `login(timeOut:)` / `loginTimeOut` | Positive finite only | Not supported — must stay positive and finite |
| `getServerHostKey(..., timeOut:)` | Positive finite only | Not supported — must stay positive and finite |
| `client.timeout` after construction | Positive finite, or `.infinity` | Set `client.timeout = .infinity` (maps to libssh2 `0`) |

On the `timeout` property, non-positive values other than `.infinity` are ignored; the setter is a silent no-op if the
client is already closed. Reading `timeout` returns `.infinity` when libssh2 has no timeout configured.
`operationsTimeOut: .infinity` is normalized to the same internal state as `nil`.

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
- By default the remote file must not already exist (uses `.exclusive`). If it does, `FileTransferErrors.remoteFileAlreadyExists` is thrown.
- Pass `resume: true` to continue an interrupted upload: if the remote file already exists, the transfer starts at its current size and appends the remaining local bytes.

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

- By default the local file must not already exist. If it does, `FileTransferErrors.localFileAlreadyExists` is thrown.
- Pass `resume: true` to continue an interrupted download: if the local file already exists, the transfer starts at its current size and appends the remaining remote bytes.

### Parallel transfers

Use `multiUpload` and `multiDownload` to split a file into byte ranges and transfer those ranges concurrently over
independent SSH/SFTP connections:

```swift
try await client.multiUpload(
    from: localFile,
    to: "/home/alice/backups/archive.zip",
    workers: 4,
    bufferSize: 1024 * 1024,
    resume: .ifPossible
) { bytesTransferred, totalBytes, lastChunkBytes, lastChunkInterval in
    return true
}

try await client.multiDownload(
    from: "/home/alice/backups/archive.zip",
    to: destination,
    workers: 4,
    resume: .ifPossible
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

Passing `resume: .ifPossible` makes `multiUpload` and `multiDownload` behave exactly as above, with one difference:
an interrupted transfer can be continued rather than restarted.

```swift
try await client.multiUpload(
    from: localFile,
    to: "/home/alice/backups/archive.zip",
    workers: 4,
    bufferSize: 1024 * 1024,
    resume: .ifPossible
) { bytesTransferred, totalBytes, lastChunkBytes, lastChunkInterval in
    let percent = Double(bytesTransferred) * 100 / Double(totalBytes)
    print(String(format: "%.0f%%", percent))
    return true     // return false to cancel; the progress made so far is kept
}

try await client.multiDownload(
    from: "/home/alice/backups/archive.zip",
    to: destination,
    workers: 4,
    resume: .ifPossible
) { _, _, _, _ in true }
```

Resuming is not a mode or a session — it is the same call, made again. A dropped connection surfaces as a thrown
error like any other, and the next call with the same source and destination transfers only the blocks that are
missing:

```swift
for attempt in 1 ... 3 {
    do {
        try await client.multiUpload(
            from: localFile,
            to: "/home/alice/backups/archive.zip",
            workers: 4,
            resume: .ifPossible
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

How progress is stored, what survives an interruption, what is not protected, and how workers relate to progress are
covered in [Resumable transfer details](ResumableTransferDetails.md).

#### Cleaning up abandoned temporaries

```swift
// Remote: temporaries left behind by a resumable multiUpload
let sweptRemote: [String] = try await client.cleanupResumableUploads(
    in: "/home/alice/backups",
    olderThan: 7 * 24 * 60 * 60     // one week, in seconds
)

// Local: temporaries left behind by a resumable multiDownload
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

For large files on the same host, prefer a [server-side copy](#server-side-copy) via the shell agent so bytes never leave the
server.

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

`SSHShellAgent` runs short commands over the same SSH session as your `SFTPClient`, using a **persistent** shell channel
rather than the SFTP subsystem. Work such as copying a file on the host or hashing a remote path stays on the server, so
the payload never crosses the network twice.

The agent does not own the TCP connection. It reuses the client's session under the same I/O lock as SFTP operations, so
shell and SFTP calls on one client never interleave libssh2 traffic. One channel is opened when you create the agent and
kept for every `copy` / `move` / `calculateHash` until you call `close()`. The client must already be logged in.

Call `close()` when you are done (same lifecycle as an open `SFTPFile`). The agent inherits the client's
`trapOnDeInitWithoutClose` setting: if that flag is `true` and the agent is destroyed without `close()`, the process
raises `SIGTRAP` in debug.

### Obtaining an agent

```swift
// Detect the remote shell family (uname, then Windows PowerShell / cmd heuristics)
let agent = try await client.shellAgent()
defer { try? await agent.close() }

print(agent.shellType)   // e.g. .darwin, .linux, .windowsPowerShell

// Or force a family when you already know the host
let linuxAgent = try await client.shellAgent(shellType: .linux)
defer { try? await linuxAgent.close() }
```

Detection throws `ShellAgentError.couldNotHeuristicallyDetectShellType` when none of the probes succeed.

### Shell types

| `ShellType` | Typical hosts | Notes |
|-------------|---------------|-------|
| `.darwin` | macOS | Uses `md5 -q` and `shasum` for digests |
| `.linux` | Linux | Uses GNU `md5sum` and `sha*sum` |
| `.posixCompatible` | FreeBSD and other Unix-like systems | Same command style as Linux where those tools exist |
| `.windowsPowerShell` | Windows with PowerShell | `Get-FileHash` / `Copy-Item` via `powershell.exe` |
| `.windowsCommandPrompt` | Windows `cmd.exe` | `certutil` / `copy` |

### Server-side copy

```swift
try await agent.copy(
    from: "/data/source.dat",
    to: "/data/archive/source.dat"
)

// Optional progress: only called when the remote tool reports a completed path (e.g. `cp -v`).
// Not cancellable. If the host emits nothing parseable, the callback is never invoked.
try await agent.copy(from: "/data/source.dat", to: "/data/archive/source.dat") { path in
    print("copied:", path)
}
```

Parent directories of `to` are created when the remote tools support it (`mkdir -p` on Unix, `New-Item` / `mkdir` on
Windows). This is the complement of [`copyClientSide`](#client-side-remote-copy): no data is streamed through your app.

### Server-side move

```swift
try await agent.move(
    from: "/data/source.dat",
    to: "/data/archive/source.dat"
)

try await agent.move(from: "/data/source.dat", to: "/mnt/other/source.dat") { path in
    print("moved:", path)
}
```

Same path rewriting and parent-directory rules as copy. Prefer `move` over SFTP rename when the source and destination
may sit on different filesystems — the remote `mv` / `Move-Item` path handles that. Progress behaves like
`copy`: only when the remote prints parseable completion lines.

### Server-side concat

Joins remote files **in order** into one destination path on the host (binary-safe):

```swift
try await agent.concat(
    files: [
        "/data/part-001.bin",
        "/data/part-002.bin",
        "/data/part-003.bin",
    ],
    to: "/data/combined.bin"
)
```

Parent directories of `to` are created when supported. An empty `files` array throws
`ShellAgentError.invalidArgument`. Under the hood this is `cat … > dest` on Unix, `copy /b` on Windows Command Prompt,
and a PowerShell stream copy when the agent is in the PowerShell family.

### Create zero-filled or random files

Generate a remote file of an exact byte length without uploading payload from the client:

```swift
// All zeros (e.g. sparse/zero-filled where the OS allows)
try await agent.createZeros(file: "/data/blank-1GiB.bin", length: 1_073_741_824)

// Host CSPRNG (/dev/urandom or Windows RandomNumberGenerator)
try await agent.createRandomData(file: "/data/random-64MiB.bin", length: 64 * 1024 * 1024)
```

`length` must be non-negative (`0` creates an empty file). Parent directories of `file` are created when supported.
Negative lengths throw `ShellAgentError.invalidArgument`.

### Create archives

Three APIs build archives on the server from remote paths. Parent directories of `output` are created when supported.
An empty `input` array (or, for ZIP / 7-Zip, a level outside `0...9`) throws `ShellAgentError.invalidArgument`.

```swift
try await agent.tar(
    input: ["/data/dir", "/data/readme.txt"],
    output: "/data/backup.tar.gz",
    compression: .gzip
)

try await agent.zip(
    input: ["/data/dir", "/data/readme.txt"],
    output: "/data/bundle.zip",
    compressionLevel: 6,
    tool: .infoZip
)

try await agent.sevenZip(
    input: ["/data/dir", "/data/readme.txt"],
    output: "/data/bundle.7z",
    compressionLevel: 9
)
```

**`tar`** — compression is limited to filters supported by **both** GNU tar and bsdtar. On Windows the built-in
`tar.exe` (bsdtar) is used with the same flags.

| `TarCompression` | Typical extension | Flag |
|------------------|-------------------|------|
| `.none` | `.tar` | — |
| `.gzip` | `.tar.gz` | `-z` |
| `.bzip2` | `.tar.bz2` | `-j` |
| `.xz` | `.tar.xz` | `-J` |
| `.compress` | `.tar.Z` | `-Z` |
| `.lzma` | `.tar.lzma` | `--lzma` |
| `.zstd` | `.tar.zst` | `--zstd` |

`.zstd` is accepted by both GNU tar and bsdtar, but GNU tar usually needs the external `zstd` program on `PATH`
(common on Raspberry Pi OS and desktop distros; not always present in minimal containers).

**`zip`** — `compressionLevel` is `0...9` (`0` = store only, `9` = maximum deflate). `tool` selects the remote
implementation:

| `ZipTool` | Remote command | Notes |
|-----------|----------------|-------|
| `.infoZip` | Info-ZIP `zip -r -[0-9]` | Common on macOS; optional package on Linux |
| `.tar` | `tar --format=zip --options zip:compression-level=N` | bsdtar / Windows `tar.exe`; not stock GNU tar |
| `.microsoft` | PowerShell `Compress-Archive` | Windows only; under Command Prompt the agent calls `powershell.exe`. Levels map to NoCompression / Fastest / Optimal |
| `.poke` | (auto) | Probes the host and picks the first available tool in order: Info-ZIP → tar ZIP → Microsoft |

`.microsoft` on a Unix shell throws `hostDoesNotSupportOperation`. If `.poke` finds no usable tool, it also throws
`hostDoesNotSupportOperation`.

**`sevenZip`** — uses the remote **7-Zip / p7zip** CLI (`7z`, then `7zz`, then `7za`). `compressionLevel` is `0...9`
(`-mxN`). The archive type generally follows the `output` extension (`.7z`, `.zip`, …). Missing 7-Zip on the host throws
`hostDoesNotSupportOperation`. Common via Homebrew (`p7zip`) on macOS and distro packages on Linux.

### Extract archives

Each extract API takes the archive path and a **destination directory**. The agent creates that directory (and parents)
through the parent `SFTPClient` when it does not already exist (`makePath: true`). There is no progress callback.

```swift
try await agent.untar(file: "/data/backup.tar.gz", to: "/data/restored")

try await agent.unzip(file: "/data/bundle.zip", to: "/data/unzipped")
// or force a tool:
try await agent.unzip(file: "/data/bundle.zip", to: "/data/unzipped", tool: .infoZip)

try await agent.unSevenZip(file: "/data/bundle.7z", to: "/data/from7z")
```

| Method | Remote tools | Notes |
|--------|--------------|-------|
| `untar` | `tar -xf … -C …` | Compression auto-detected (gzip, xz, …) by GNU tar / bsdtar |
| `unzip` | Info-ZIP `unzip`, `tar` ZIP extract, or `Expand-Archive` | Same `ZipTool` / `.poke` preference as create, but probes `unzip` / `Expand-Archive` for extract |
| `unSevenZip` | `7z` / `7zz` / `7za` `x -y -bd -o…` | Same binary preference as `sevenZip` |

Empty `file` or `to` throws `invalidArgument`. Missing tooling throws `hostDoesNotSupportOperation` where applicable.

### Download a URL onto the server

Fetches with remote **`curl`** (or **`curl.exe`** on Windows so PowerShell does not use the `Invoke-WebRequest` alias).
The payload never crosses the SFTP client. Parent directories of `file` are created via SFTP when missing.

```swift
try await agent.download(
    url: URL(string: "https://example.com/payload.bin")!,
    file: "/data/payload.bin",
    headers: ["Authorization: Bearer token"]
)
// or without headers:
try await agent.download(
    url: URL(string: "https://example.com/payload.bin")!,
    file: "/data/payload.bin"
)
```

Uses `curl -fsSL -o …` (fail on HTTP errors, quiet with errors shown, follow redirects). Missing `curl` throws
`hostDoesNotSupportOperation`.

### Calculating a remote hash

```swift
let digest: Data = try await agent.calculateHash(
    file: "/data/source.dat",
    algorithm: .sha256
)
// raw digest bytes (not hex-encoded)
```

Supported algorithms depend on the remote tooling:

| Algorithm | `.darwin` | `.linux` / `.posixCompatible` | Windows (PowerShell / cmd) |
|-----------|:---------:|:-----------------------------:|:--------------------------:|
| `.md5` | ✓ | ✓ | ✓ |
| `.sha1` | ✓ | ✓ | ✓ |
| `.sha224` | ✓ | ✓ | — |
| `.sha256` | ✓ | ✓ | ✓ |
| `.sha384` | ✓ | ✓ | ✓ |
| `.sha512` | ✓ | ✓ | ✓ |
| `.sha512224` | ✓ | — | — |
| `.sha512256` | ✓ | — | — |

Unsupported combinations throw `ShellAgentError.hostDoesNotSupportOperation`. A non-zero remote exit becomes
`ShellAgentError.commandFailed(exitCode:stdout:stderr:)`.

### Paths on Windows

Shell-agent APIs accept the same SFTP path form as the rest of the client (`/C:/Users/alice/file.txt`). On Windows
shells, paths are rewritten to native form (`C:\Users\alice\file.txt`) before the command runs. You may also pass native
Windows paths; they are normalized first.

```swift
// All three resolve to the same remote file on OpenSSH for Windows
try await agent.calculateHash(file: "/C:/Users/alice/report.pdf", algorithm: .sha256)
try await agent.calculateHash(file: #"C:\Users\alice\report.pdf"#, algorithm: .sha256)
try await agent.calculateHash(
    file: #"C:\Users\alice\report.pdf"#.sftpPathFromWindows,   // → "/C:/Users/alice/report.pdf"
    algorithm: .sha256
)
```

The inverse helper `windowsPathFromSFTP` converts SFTP form back to native Windows paths when you need them outside the
agent. See [Windows SFTP servers and path notation](#windows-sftp-servers-and-path-notation).

### Requirements and limits

- The SSH server must allow `exec` (not SFTP-only lockdowns that reject session channels).
- The remote host must ship the expected tools for the detected shell family (`cp` / `md5sum` / `sha*sum` / `shasum` /
  `md5`, or PowerShell / `certutil` on Windows).
- Prefer server-side copy for same-host renames of large files; use client-side copy when the SFTP server cannot run
  shell commands or when you need progress callbacks over the transfer path.

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
| `.invalidTimeOutValue` | Invalid timeout for the API in use (see [Timeouts](#timeouts)). For `operationsTimeOut`, negative/zero/NaN; for login/`getServerHostKey`, also infinite. Not thrown by the runtime `timeout` property |
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
| `.resumableTrailerVersionUnsupported(version:path:)` | A resumable transfer found a partial file written by a newer release of SwiftSFTP. The partial file is preserved, not deleted; `resume: .discardingProgress` discards it and starts over |
| `.resumableTruncateUnsupported(path:)` | Every byte arrived, but the server refused to shrink the trailer away, so the rename was skipped. The partial file is preserved with every block marked done, and a later run finishes it without re-transferring anything |
| `.resumableDestinationNameTooLong(byteCount:maximum:)` | Destination file name is longer than the 4096 bytes a trailer can record; refused before anything is created |

### State errors

| Type | Cause |
|------|-------|
| `AlreadyClosed` | Operation called on a closed client or file handle |
| `NotLoggedIn` | Operation called before `login()` |

### Shell agent errors (`ShellAgentError`)

Thrown by `shellAgent(shellType:)` and by `SSHShellAgent` operations:

| Case | Cause |
|------|-------|
| `.couldNotHeuristicallyDetectShellType` | Auto-detection could not identify a supported remote shell |
| `.hostDoesNotSupportOperation` | Requested hash algorithm (or equivalent) is unavailable on that shell family |
| `.commandFailed(exitCode:stdout:stderr:)` | Remote command exited non-zero |
| `.unexpectedOutput(String)` | Command output could not be parsed (for example a hash line) |
| `.invalidArgument(String)` | Caller passed an unusable argument (for example an empty `files` list to `concat`) |

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
