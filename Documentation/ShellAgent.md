# SwiftSFTP — Shell Agent

`SSHShellAgent` runs short commands over the same SSH session as your `SFTPClient`, using a **persistent** shell channel
rather than the SFTP subsystem. Work such as copying a file on the host or hashing a remote path stays on the server, so
the payload never crosses the network twice.

The agent works on a logged-in `SFTPClient`; for connecting, transfers, and everything else, see the
[User's Guide](UserGuide.md). The errors it throws are listed under
[Shell agent errors](UserGuide.md#shell-agent-errors-shellagenterror).

## Table of Contents

1. [How the agent works](#how-the-agent-works)
2. [Obtaining an agent](#obtaining-an-agent)
3. [Shell types](#shell-types)
4. [Server-side copy](#server-side-copy)
5. [Server-side move](#server-side-move)
6. [Server-side concat](#server-side-concat)
7. [Create zero-filled or random files](#create-zero-filled-or-random-files)
8. [Create archives](#create-archives)
9. [Extract archives](#extract-archives)
10. [Download a URL onto the server](#download-a-url-onto-the-server)
11. [Calculating a remote hash](#calculating-a-remote-hash)
12. [Reading file metadata (`stat`)](#reading-file-metadata-stat)
13. [Paths on Windows](#paths-on-windows)
14. [Requirements and limits](#requirements-and-limits)

---

## How the agent works

The agent does not own the TCP connection. It reuses the client's session under the same I/O lock as SFTP operations, so
shell and SFTP calls on one client never interleave libssh2 traffic. One channel is opened when you create the agent and
kept for every `copy` / `move` / `calculateHash` until you call `close()`. The client must already be logged in.

Unix-like hosts run commands under a persistent `/bin/sh -s` channel (not bash). Windows hosts use a persistent
`cmd.exe /K` session; PowerShell tool bodies still run as one-shot `powershell.exe` children under that cmd.

While a framed shell command is waiting for completion, the agent temporarily disables the session's ordinary blocking
timeout so long silent remote work (large copies, archives, downloads) is not cut short by a short `operationsTimeOut`.
If a command fails mid-stream in a way that may desynchronize the channel, the agent closes itself and further
operations throw `AlreadyClosed`.

Call `close()` when you are done (same lifecycle as an open `SFTPFile`). The agent inherits the client's
`trapOnDeInitWithoutClose` setting: if that flag is `true` and the agent is destroyed without `close()`, the process
raises `SIGTRAP` in debug. Closing the agent after the parent client is already closed is safe (no trap).

---

## Obtaining an agent

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

---

## Shell types

| `ShellType` | Typical hosts | Notes |
|-------------|---------------|-------|
| `.darwin` | macOS | Uses `md5 -q` and `shasum` for digests |
| `.linux` | Linux | Uses GNU `md5sum` and `sha*sum` |
| `.posixCompatible` | FreeBSD and other Unix-like systems | Same command style as Linux where those tools exist |
| `.windowsPowerShell` | Windows with PowerShell | `Get-FileHash` / `Copy-Item` via `powershell.exe` |
| `.windowsCommandPrompt` | Windows `cmd.exe` | `certutil` / `copy` |

---

## Server-side copy

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
Windows). This is the complement of [`copyClientSide`](UserGuide.md#client-side-remote-copy): no data is streamed through your app.

---

## Server-side move

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

---

## Server-side concat

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

---

## Create zero-filled or random files

Generate a remote file of an exact byte length without uploading payload from the client:

```swift
// All zeros (e.g. sparse/zero-filled where the OS allows)
try await agent.createZeros(file: "/data/blank-1GiB.bin", length: 1_073_741_824)

// Host CSPRNG (/dev/urandom or Windows RandomNumberGenerator)
try await agent.createRandomData(file: "/data/random-64MiB.bin", length: 64 * 1024 * 1024)
```

`length` must be non-negative (`0` creates an empty file). Parent directories of `file` are created when supported.
Negative lengths throw `ShellAgentError.invalidArgument`.

---

## Create archives

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

---

## Extract archives

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

---

## Download a URL onto the server

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

---

## Calculating a remote hash

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

---

## Reading file metadata (`stat`)

SFTP attributes carry whole seconds. `stat` runs the host's own `stat` and returns timestamps at the resolution the file
system keeps (nanoseconds on APFS and ext4, 100 ns on NTFS), plus size, kind, permissions, owner and inode on Unix hosts:

```swift
let status = try await agent.stat(file: "/data/report.pdf")
print(status.kind, status.size, status.modificationDate)
print(status.creationDate as Any)   // nil when the host does not record birth time

// Describe a symlink itself, and read its extended attributes
let link = try await agent.stat(file: "/data/latest", options: [.noFollowSymlinks, .extendedAttributes])
print(link.extendedAttributes ?? [:])
```

| Option | Effect |
|--------|--------|
| `.noFollowSymlinks` | Describes a link itself (`lstat`) instead of its target. Ignored on Windows. |
| `.extendedAttributes` | Also reads extended attributes with a second command: `xattr` on macOS, `getfattr` on Linux. Throws `hostDoesNotSupportOperation` elsewhere, including Windows. |

Fields the host does not record are `nil`: `creationDate` on older Linux kernels, and `changeDate`, `permissions`,
`ownerID`, `groupID` and `inode` on Windows. A `Date` holds roughly a tenth of a microsecond at today's epoch, so the
last digits of a nanosecond timestamp may round. A path that does not exist throws
`ShellAgentError.commandFailed(exitCode:stdout:stderr:)`, and a `stat` that prints an unknown format (BusyBox, for
example) throws `ShellAgentError.unexpectedOutput(_:)`. On Windows, PowerShell and `cmd` were checked against OpenSSH for Windows 9.5, and the parsers are covered by unit tests.

---

## Paths on Windows

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
agent. See [Windows SFTP servers and path notation](UserGuide.md#windows-sftp-servers-and-path-notation).

---

## Requirements and limits

- The SSH server must allow `exec` (not SFTP-only lockdowns that reject session channels).
- The remote host must ship the expected tools for the detected shell family (`cp` / `md5sum` / `sha*sum` / `shasum` /
  `md5`, or PowerShell / `certutil` on Windows).
- Prefer server-side copy for same-host renames of large files; use client-side copy when the SFTP server cannot run
  shell commands or when you need progress callbacks over the transfer path.
