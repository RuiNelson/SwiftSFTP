# Migrating from SwiftSFTP 3.24 to 4.0

SwiftSFTP 4.0 changes how the library reports problems, how objects are released, and how files are transferred over
several connections. Most programs need only a few mechanical edits; the compiler finds nearly all of them. This guide
lists every source-breaking change and every change in runtime behaviour, with what to do about each.

## At a glance

| 3.24 | 4.0 |
|------|-----|
| macOS 11, iOS 14, tvOS 14, watchOS 7, Mac Catalyst 14 | macOS 12, iOS 15, tvOS 15, watchOS 9, Mac Catalyst 15 |
| Depends on swift-log | No logging dependency; SwiftSFTP logs nothing |
| `logger:` and `trapOnDeInitWithoutClose:` parameters | `deinitErrorHandler:` parameter |
| `close()` required on clients, files, and shell agents | `close()` optional: a released object closes itself |
| `SFTPClient(...)` then `login(timeOut:)`, or `initAndLogin(...)` | `try await SFTPClient(...)`: the initializer logs in |
| `fork(loggedIn:)` | `fork()`, always logged in |
| Configuration checked by the synchronous `init` | `preflightConfigurationCheck(_:hostKeyAcceptance:authentication:)` |
| `AlreadyClosed`, `NotLoggedIn` thrown | Misuse: assertion failure in debug, `MisuseError` thrown in release; no "not logged in" state |
| Invalid timeouts, buffer sizes, keepalive intervals, URLs thrown or ignored | Precondition failure in every build |
| `.privateKeys(PrivateKeySet)`, `.privateKeyFile`, `.privateKeyString` | `.privateKey(PrivateKey)`, `.privateKeys([PrivateKey])` |
| `contentsOfDirectory(path:recursive:)` | `listDirectory(path:recursive:)`, returning `[FileMetadata]` |
| Deprecated `listDirectory(path:recursive:) -> Set<FileMetadata>` | Removed; the name now returns `[FileMetadata]` |
| `multiUpload`, `multiDownload`, `multiTune`, `ResumeBehavior`, `TransferDirection` | `SFTPSwarm`, with `upload`, `download`, `autoTuneForUpload`, `autoTuneForDownload` |
| `upload(from:to:resume:...)`, `download(from:to:resume:...)` as extension methods | Requirements of `SFTPClientProtocol`; call sites and `SFTPClient` behaviour unchanged |
| `makeAsset(at:readAheadSize:stripeSize:...)`, `makePlayerItem(at:...)` | `await makeAsset(path:readAhead:bufferSize:...)`, `await makePlayerItem(path:...)` |
| `makeAsset` / `makePlayerItem` on a collection of clients | The same methods on an `SFTPSwarm` |
| `TraceSetToLogger(session:options:)` | Removed; use `TraceSetHandler` and `Trace` |
| `ReferenceCache.close()` | Removed; release the cache, or call `removeAll()` |
| Deprecated `SwiftSFTP_Curve25519`, `OpenSSHKeyPair` | Removed; use `AsymmetricCryptography.EdDSA.Ed25519` with `PrivateKey` and `PublicKey` |
| `SFTPClientInvalidConfig.authenticationFailed(_:)` | `UserAuthenticationError` |
| File sizes, byte counts, and offsets as `Int64` (`TransferProgress`, `directorySize`, `set(size:)`, `upTo:`, `createZeros(length:)`) | `FileSize` and `FileOffset`, both `UInt64` |
| `getServerHostKey(openSocketIn:timeOut:shortHandForm:)` | `getServerHostKey(_:timeOut:)`, always a `known_hosts` line |
| `HostKeyAcceptance.shortHandAcceptedKeys(_:)` | `.loadKnownHostsString(_:)` with lines built from `TCPLocation.knownHostsFormat` |
| `.loadFromFile(file:)`, `.loadFromFileString(file:)` | `.loadKnownHostsFile(_:)`, `.loadKnownHostsString(_:)` |

## Updating the dependency

```swift
dependencies: [
    .package(url: "https://github.com/RuiNelson/SwiftSFTP.git", from: "4.0.0")
]
```

The same applies to the `EXIFKit` and `LegacyAlgorithms` traits:

```swift
.package(url: "https://github.com/RuiNelson/SwiftSFTP.git", from: "4.0.0", traits: ["EXIFKit"])
```

### Platform minimums

The minimum deployment targets went up:

| Platform | 3.24 | 4.0 |
|----------|------|-----|
| macOS | 11 | 12 |
| iOS | 14 | 15 |
| tvOS | 14 | 15 |
| watchOS | 7 | 9 |
| Mac Catalyst | 14 | 15 |
| visionOS | 1 | 1 (unchanged) |
| Android | API 28 | API 28 (unchanged) |

Linux and Windows are unaffected. Raise your own package's or app's deployment target if it is below these.

### Dependencies

- **swift-log is gone.** SwiftSFTP no longer depends on it and logs nothing itself. If your package only got
  `Logging` through SwiftSFTP, add swift-log as a direct dependency or stop importing it. If you listed swift-log in a
  licence notice only because of SwiftSFTP, you can drop it.
- **PathWorks** now needs 2.1.0 or later (`.upToNextMajor(from: "2.1.0")`). A package that pins PathWorks below 2.1.0
  no longer resolves.

## Replacing `logger` and `trapOnDeInitWithoutClose`

`SFTPClient.init` and the `SFTPClientProtocol` initializer lose both parameters and gain `deinitErrorHandler`. (The
initializer also replaces `initAndLogin`: see [The initializer logs in](#the-initializer-logs-in).)

**Before (3.24):**

```swift
let client = try await SFTPClient.initAndLogin(
    openSocketIn: location,
    authentication: auth,
    logger: logger,
    trapOnDeInitWithoutClose: true
)
```

**After (4.0):**

```swift
let client = try await SFTPClient(
    location,
    authentication: auth,
    deinitErrorHandler: { error in  // optional
        logger.error("\(error.localizedDescription)")
    }
)
```

- If you passed neither parameter, nothing changes at the call site.
- If you passed `trapOnDeInitWithoutClose:`, delete it. Releasing an object without `close()` is supported now (see
  [Closing is optional](#closing-is-optional)), so there is nothing left to trap on.
- If you passed `logger:`, delete it, or pass a `deinitErrorHandler` that forwards to your logger. In 3.24 the logger
  received warnings about closing and deinitialization; in 4.0 the only failures with nowhere else to go are those of
  objects closing themselves after being released, and those are what the handler receives.

The handler is a `DeinitErrorHandler`, `@Sendable (DeinitError) -> Void`, and can be called from any thread. A
`DeinitError` carries its `source` (`.sftpClient`, `.sftpFile`, or `.sshShellAgent`) and its `underlyingError`. The
default, `debugPrintDeinitErrorHandler`, prints the error in debug builds and ignores it in release builds. File
handles, shell agents, and forks share the handler of the client they came from.

Note that in 3.24 `initAndLogin` defaulted `trapOnDeInitWithoutClose` to `true`, so a debug build raised `SIGTRAP` for
a client released without `close()`. That no longer happens.

### `multiTune`

`multiTune` is removed altogether, so its `logger:` has nothing to become: see
[Multi-connection transfers become `SFTPSwarm`](#multi-connection-transfers-become-sftpswarm) for what replaces it.

### Layer 0 tracing

`TraceSetToLogger(session:options:)` is removed. Install your own handler with `TraceSetHandler(session:context:handler:)`
and enable categories with `Trace(session:options:)`:

```swift
try TraceSetHandler(session: session) { _, _, data, length in
    guard let data else { return }
    let message = String(decoding: UnsafeRawBufferPointer(start: data, count: length), as: UTF8.self)
    print(message)
}
try Trace(session: session, options: [.sftp])
```

`LibSSH2TraceHandler` is a C function pointer, so the closure cannot capture context; pass anything it needs through
`context`.

## The initializer logs in

`SFTPClient.init` now connects, authenticates, and initializes SFTP, as `initAndLogin` did: a client that exists is
logged in. It is `async throws`, and it throws the connection, host-key, and authentication errors that `login(timeOut:)`
threw, besides `SFTPClientInvalidConfig`. When it fails, the client closes what it opened before throwing.

- `initAndLogin(...)` and `login(timeOut:)` are removed.
- The first parameter loses its `openSocketIn:` label: write `SFTPClient(location, ...)`.
- `loginTimeOut` (default `10.0`) is new, after `compressionPreference`, and `operationsTimeOut` moves after it. The
  parameter order is now `_ openSocketIn`, `hostKeyAcceptance`, `authentication`, `compressionPreference`,
  `loginTimeOut`, `operationsTimeOut`, `deinitErrorHandler`.
- `fork(loggedIn:)` becomes `fork()`, which always returns a logged-in client. A fork also keeps the teardown grace
  period, read-ahead, and write-ahead of the client it came from.
- `MisuseError.clientUsedBeforeLogin` is removed, and so is the assertion on logging in twice: neither can happen.

**Before (3.24):**

```swift
let client = try SFTPClient(
    openSocketIn: location,
    operationsTimeOut: 30,
    hostKeyAcceptance: .loadFromFile(file: knownHosts),
    authentication: auth
)
try await client.login(timeOut: 15)

let worker = try await client.fork(loggedIn: true)
```

**After (4.0):**

```swift
let client = try await SFTPClient(
    location,
    hostKeyAcceptance: .loadKnownHostsFile(knownHosts),
    authentication: auth,
    loginTimeOut: 15,
    operationsTimeOut: 30
)

let worker = try await client.fork()
```

A call to `initAndLogin` becomes a call to the initializer with the same arguments, with `loginTimeOut` and
`operationsTimeOut`, in that order, moved after `compressionPreference`.

### Authentication failures have their own error

The server rejecting the credentials is a runtime condition, not an invalid configuration, so it is no longer a case of
`SFTPClientInvalidConfig`: `SFTPClientInvalidConfig.authenticationFailed(_:)` is removed, and the initializer throws
`UserAuthenticationError` instead, as it throws `HostKeyVerificationError` for the host key.

| 3.24 | 4.0 |
|------|-----|
| `.authenticationFailed(error)`, the server rejected the password or every private key | `UserAuthenticationError.rejected(error)`, with the same underlying error |
| `.authenticationFailed(LibSSH2Error.methodNotSupported(…))`, no private key matches `server-sig-algs` | `UserAuthenticationError.noKeyMatchesServerAlgorithms(serverAlgorithms:)` |

```swift
// Before
catch SFTPClientInvalidConfig.authenticationFailed(let error) { … }

// After
catch UserAuthenticationError.rejected(let error) { … }
catch UserAuthenticationError.noKeyMatchesServerAlgorithms(let serverAlgorithms) { … }
```

`SFTPClientInvalidConfig` now holds only what `preflightConfigurationCheck` can find without connecting.

### Checking a configuration without connecting

Code that created a client only to validate its configuration, without logging in, calls
`SFTPClient.preflightConfigurationCheck(_:hostKeyAcceptance:authentication:)` instead. It runs the checks the
initializer runs before connecting — hostname, port, username, authentication material, and host-key acceptance data,
loaded into a libssh2 session that it then frees — and throws `SFTPClientInvalidConfig`:

```swift
// Before
_ = try SFTPClient(openSocketIn: location, hostKeyAcceptance: acceptance, authentication: auth)

// After
try SFTPClient.preflightConfigurationCheck(location, hostKeyAcceptance: acceptance, authentication: auth)
```

## Closing is optional

In 3.24, `close()` was required on a client, a file, and a shell agent. In 4.0 an object released without `close()`
closes itself:

- A **client** drops its socket and frees everything at once, without the polite goodbye `close()` sends. Releasing a
  client never blocks.
- A **file** sends its `SSH_FXP_CLOSE` from a task of its own, which keeps the client alive until the server answers.
  A cached file still hands the cache its final attributes.
- A **shell agent** closes its channel on the client's session queue.

A failure while doing so goes to the client's `deinitErrorHandler`.

Existing `close()` calls keep working and you do not have to remove them. Keep them where the outcome matters, because
`close()` waits for the server and throws:

- before renaming a file you just wrote (Windows servers refuse to rename an open file);
- before reading the file from another connection;
- where a write error that the server reports only at close must not go unnoticed;
- to unblock a call stuck on an unresponsive peer.

`defer { try? await client.close() }` blocks are still valid but are no longer needed only to avoid a leak or a trap.

### `ReferenceCache.close()` is removed

A cache no longer has `close()`. Releasing it releases its shell agent and leaves the bytes it stored in its storage,
which evicts them as it evicts any others. To drop them at once, call `removeAll()`, which is now public; the cache keeps
working afterwards.

```swift
// Before
client.detachCache()
await cache.close()
try await control.close()

// After
client.detachCache()
await cache.removeAll()  // optional
try await control.close()
```

The control connection is still yours to close.

## `AlreadyClosed` and `NotLoggedIn` become `MisuseError`

The `AlreadyClosed` and `NotLoggedIn` types are removed. Using a client after `close()` is a bug in the calling code,
and 4.0 treats it as one. A client can no longer exist without being logged in (see
[The initializer logs in](#the-initializer-logs-in)), so `NotLoggedIn` has no replacement:

- **Debug builds** stop at the misuse with an assertion failure, so you find it where it happens.
- **Release builds** throw `MisuseError`, so that neither a made-up value nor a step that never ran reaches the caller
  as a success.

| Situation | 3.24 | 4.0 debug | 4.0 release |
|-----------|------|-----------|-------------|
| Client used after its `close()` (including files and shell agents opened from it, and an operation that was waiting for the connection when another task closed it) | `AlreadyClosed` | Assertion failure | `MisuseError.clientUsedAfterClosing` |
| File used after its `close()` | `AlreadyClosed` | Assertion failure | `MisuseError.fileUsedAfterClosing` |
| Shell agent used after its `close()` | `AlreadyClosed` | Assertion failure | `MisuseError.shellAgentUsedAfterClosing` |
| Closing a file or shell agent whose client is already closed | File: `AlreadyClosed`; agent: no error | Does nothing | Does nothing |
| Closing twice | Logged a warning | Does nothing | Does nothing |

An operation already running on the connection when another task closes the client is not a misuse: it fails with the
`LibSSH2Error` of the socket the close shut down, as before.

What to change:

- **`catch is NotLoggedIn`**: no longer compiles, and the situation it caught no longer exists; remove it.
- **`catch is AlreadyClosed`**: no longer compiles. If the catch handled a real race (for
  example a background task that may outlive the client), fix the race: check `closed` first, cancel the task before
  closing, or keep the client alive until the task ends. Catching `MisuseError` instead only helps release builds; debug
  builds stop before the throw.
- **Tests that expected `AlreadyClosed`** should assert that the operation is not reached, or be removed. A test that
  must exercise the release-build throw needs a release build.
- **AVFoundation**: closing a client or swarm under a playing asset is a misuse. Keep it open until playback and
  metadata loading finish. `MediaLoadingError` now recognises `MisuseError` where it recognised `AlreadyClosed`; in a release build the following media reads fail with `ENOTCONN`.
- **EXIFKit**: reading a thumbnail after its handle or client closed is a misuse instead of an `AlreadyClosed` throw.
  Use `try await metadata.loadingThumbnail()` if you want to close the handle early.

### Shell agent closed after a failed command

A shell agent whose command failed part way, in a way that may desynchronise the channel, closes itself, as in 3.24.
Its later operations now throw `ShellAgentError.channelClosedAfterFailure`, a runtime error, instead of `AlreadyClosed`.
Catch it and open a new agent with `shellAgent(shellType:)`.

## Impossible values stop the process

Values that no correct program passes now fail a `precondition` in every build, debug and release, instead of being
thrown or silently ignored. Validate them before calling SwiftSFTP if they come from user input or configuration.

| Where | Value | 3.24 | 4.0 |
|-------|-------|------|-----|
| `operationsTimeOut` (`init`) | Zero, negative, NaN | Threw `SFTPClientInvalidConfig.invalidTimeOutValue` | Precondition failure |
| `loginTimeOut` (`init`, formerly `login(timeOut:)`), `getServerHostKey(timeOut:)` | Zero, negative, NaN | Threw `.invalidTimeOutValue` | Precondition failure |
| `loginTimeOut` (`init`, formerly `login(timeOut:)`), `getServerHostKey(timeOut:)` | `.infinity` | Threw `.invalidTimeOutValue` | **Accepted**: no timeout |
| `client.timeout` setter | Zero, negative, NaN | Ignored | Precondition failure |
| `client.teardownGracePeriod` setter | Zero, negative, NaN | Ignored | Precondition failure |
| `setKeepAlive(every:)` | Zero, negative, NaN, infinite, too large for libssh2 | Threw `SFTPClientInvalidConfig.invalidKeepAliveInterval` | Precondition failure (`nil` still disables keepalives) |
| Transfers | `bufferSize` or `chunkSize` below one | Threw `FileTransferErrors.invalidBufferSize` | Precondition failure |
| Transfers | Local URL that is not a `file://` URL | Threw `FileTransferErrors.notAFileURL` | Precondition failure |
| `SFTPFile.read(upTo:)` | `upTo` below one | `read(upTo: 0)` returned `nil` | Precondition failure |
| `UserAuthentication` | Empty `PrivateKeySet` (now an empty `.privateKeys([])`) | Threw `SFTPClientInvalidConfig.invalidPrivateKey` at login | Precondition failure in `SFTPClient.init` |
| Shell agent | Empty input list to `tar`, `zip`, `sevenZip`, `concat` | Threw `ShellAgentError.invalidArgument` | Precondition failure |
| Shell agent | `compressionLevel` outside `0...9` | Threw `ShellAgentError.invalidArgument` | Precondition failure |

As a result these enum cases are removed, and a `switch` or `catch` naming them no longer compiles:

- `SFTPClientInvalidConfig.invalidTimeOutValue`
- `SFTPClientInvalidConfig.invalidKeepAliveInterval`
- `FileTransferErrors.notAFileURL`
- `FileTransferErrors.invalidBufferSize`

`SFTPClientInvalidConfig.invalidPrivateKey` remains, for a private key of a type SSH cannot authenticate with (see
[Private keys are `PrivateKey` values](#private-keys-are-privatekey-values)).
`ShellAgentError.invalidArgument` remains, but is thrown only for an empty path (to `stat`, and the archive or
destination of `untar`, `unzip`, `unSevenZip`, and `download`), an empty download URL, and an unknown 7-Zip binary name.

## Private keys are `PrivateKey` values

`UserAuthenticationMode` takes parsed `PrivateKey` values instead of key text or file URLs. `PrivateKeySet`,
`PrivateKeyString`, and `PrivateKeyFile` are removed, and so are the deprecated `.privateKeyFile(file:password:)` and
`.privateKeyString(keyData:password:)` cases.

| 3.24 | 4.0 |
|------|-----|
| `.privateKeys(.init(url, passphrase: p))`, `.privateKeyFile(file: url, password: p)` | `.privateKey(try PrivateKey(file: url, passphrase: p))` |
| `.privateKeys(.init(pem, passphrase: p))`, `.privateKeyString(keyData: pem, password: p)` | `.privateKey(try PrivateKey(string: pem, passphrase: p))` |
| `.privateKeys(PrivateKeySet(strings: …, files: …))` | `.privateKeys([PrivateKey])`, in the order you want for keys of the same algorithm |
| `PrivateKeyString` / `PrivateKeyFile` `.valid`, `.isValidForSSH`, `.algorithm` | `try PrivateKey(string:passphrase:)`, its `validForSSHAuth`, `SSHUserKeyAlgorithm(privateKey:)` |

```swift
// Before
let auth = UserAuthentication(name: "alice", auth: .privateKeys(.init(keyURL, passphrase: "secret")))

// After
let auth = try UserAuthentication(name: "alice", auth: .privateKey(PrivateKey(file: keyURL, passphrase: "secret")))
```

Keys are read, decrypted, and checked when you create the `PrivateKey`, not at login:

- A missing file, malformed key, or wrong passphrase throws from the `PrivateKey` initializer, instead of
  `SFTPClientInvalidConfig.invalidPrivateKey` (missing file) or `SFTPClientInvalidConfig.authenticationFailed` (the
  rest) from the client.
- A key file is read once; changing it on disk afterwards does not affect a client that already has the key.
- A valid key of a type SSH cannot authenticate with (Ed448, ML-DSA, SLH-DSA, RSA under 1024 bits) makes the client
  initializer throw `SFTPClientInvalidConfig.invalidPrivateKey`; 3.24 skipped it at login.
- `UserAuthentication` encodes a key as its DER bytes, unencrypted. Data encoded by 3.24 does not decode.

## Host keys are `known_hosts` lines

The shorthand host key form, `algorithm base64` without a host, is gone, and the `HostKeyAcceptance` cases are
renamed:

| 3.24 | 4.0 |
|------|-----|
| `getServerHostKey(openSocketIn:timeOut:shortHandForm:)` | `getServerHostKey(_:timeOut:)`, always a `known_hosts` line |
| `.shortHandAcceptedKeys(keys)` | `.loadKnownHostsString(_:)`, with each key prefixed by `TCPLocation.knownHostsFormat` |
| `.loadFromFile(file:)` | `.loadKnownHostsFile(_:)` |
| `.loadFromFileString(file:)` | `.loadKnownHostsString(_:)` |
| `String.isValid_ShortHandHostKey` | Removed; check the line you build with `isValid_HostKey` |

- `getServerHostKey` takes the location without a label and loses `shortHandForm`. It always returns the full
  `known_hosts` line, `host algorithm base64`, as `shortHandForm: false` did. 3.24 defaulted to `true`, so a call that
  omitted the argument now gets the host field too.
- `TCPLocation.knownHostsFormat` is public: the host field of the line, the bare host for port 22 and `[host]:port`
  otherwise. It was the internal `knownHostsHost`.

Keys you stored in the shorthand form keep working once you prefix each with the host field of the location it belongs
to:

```swift
// Before
let storedKey = try await SFTPClient.getServerHostKey(openSocketIn: location)    // "ssh-ed25519 AAAA…"
hostKeyAcceptance: .shortHandAcceptedKeys([storedKey])

// After
let storedLine = try await SFTPClient.getServerHostKey(location)                 // "[host]:2222 ssh-ed25519 AAAA…"
hostKeyAcceptance: .loadKnownHostsString(storedLine)

// Keys stored by 3.24
let lines = storedKeys.map { "\(location.knownHostsFormat) \($0)" }
hostKeyAcceptance: .loadKnownHostsString(lines.joined(separator: "\n"))
```

Rewrite stored keys once, at the first launch of the new version, rather than at every connection, and use the
location they were saved for: a key accepted for port 22 does not match the same host on port 2222. Check each
rewritten line with `isValid_HostKey`.

`HostKeyAcceptance` is `Codable`, and its encoding names the case. A value encoded by 3.24 does not decode, unless it
is `.acceptAny`; decode it yourself, or store the keys apart from it.

## The `KeyValidation` `String` checks are removed

The `KeyValidation` protocol and its `String` conformance are gone, with every `isValid_…` and `isValidForSSH_…` check
on key text. Parse the key instead: a key that parses is valid, and the error says why one that does not was rejected.

| 3.24 | 4.0 |
|------|-----|
| `s.isValid_PrivateKey(passphrase: p)` | `PrivateKey(string: s, passphrase: p) != nil` |
| `s.isValid_PublicKey` | `PublicKey(string: s) != nil` |
| `s.isValidForSSH_PrivateKey(passphrase: p)` | `(try? PrivateKey(string: s, passphrase: p))?.validForSSHAuth == true` |
| `s.isValidForSSH_PublicKey` | `(try? PublicKey(string: s))?.validForSSHAuth == true` |
| `s.privateKeyType(passphrase: p)`, `s.publicKeyType` | `try? PrivateKey(string: s, passphrase: p).type`, `try? PublicKey(string: s).type` |
| `s.isValid_P256_PrivateKey`, `s.isValid_RSA_PublicKey`, … | Compare `.type` with `.ecdsaP256`, `.rsa`, … |
| the `password:` variants | The `passphrase:` initializers |

`String.isValid_HostKey` stays; `isValid_ShortHandHostKey` is removed (see
[Host keys are `known_hosts` lines](#host-keys-are-known_hosts-lines)).

## `contentsOfDirectory` is now `listDirectory`

`contentsOfDirectory(path:recursive:)` is renamed `listDirectory(path:recursive:)`. It returns `[FileMetadata]` as
before, in the server's order, keeping every entry. The deprecated 3.24 `listDirectory(path:recursive:)` that returned
`Set<FileMetadata>` is removed, and its name now belongs to the array-returning method.

```swift
// Before
let entries = try await client.contentsOfDirectory(path: "uploads")

// After
let entries = try await client.listDirectory(path: "uploads")
```

If you still called the deprecated `Set`-returning `listDirectory`, the call compiles but now returns an array. Code
that needs a set has to build one; be aware that a set merges entries whose names differ only in Unicode normalization,
which is why the `Set` form was deprecated:

```swift
let set = Set(try await client.listDirectory(path: "uploads"))
```

## File sizes and offsets are `UInt64`

Every file size, byte count, and offset is now an unsigned 64-bit integer, which is what the SFTP protocol sends on the
wire. 3.24 mixed `Int64` and `UInt64` for the same quantities, so callers converted at the seams, and a negative size
was a value that the API had to accept and then ignore or reject. The public aliases `FileSize` and `FileOffset` name
the two roles; both are `UInt64`, so the aliases never need a conversion between them.

The offsets, `FileAttributes.fileSize`, `SFTPFileProtocol.offset`, and the cache and `ReferenceCache` APIs were already
`UInt64`; their signatures now spell the alias, which changes nothing for callers. The following were `Int64` and are
now `FileSize`:

| API | 3.24 | 4.0 |
|-----|------|-----|
| `TransferProgress` (the callback of `upload`, `download`, `write(from:)`, `read(to:)`, and the file-to-file `read(from:)`/`write(to:)`) | `(Int64, Int64, Int, TimeInterval) async -> Bool` | `(FileSize, FileSize, Int, TimeInterval) async -> Bool` |
| `directorySize(_:)` | Returned `Int64` | Returns `FileSize` |
| `set(size:owner:date:permissions:)` on a file, `setAttributes(path:size:owner:date:permissions:)` | `size: Int64?`; a negative size was ignored | `size: FileSize?` |
| `read(from:upTo:chunkSize:continuation:)`, `write(to:upTo:chunkSize:continuation:)` between handles | `upTo: Int64?`; any value of zero or below copied nothing | `upTo: FileSize?`; zero copies nothing |
| `SSHShellAgent.createZeros(file:length:)`, `createRandomData(file:length:)` | `length: Int64`; a negative length stopped the process | `length: FileSize` |
| Layer 0 `SCPSend64(session:path:mode:size:…)` | `size: Int64` | `size: UInt64` |

The compiler finds every caller that names `Int64` explicitly. Closures that only do arithmetic on the progress values
need no change, apart from places that mixed them with signed values:

```swift
// Before
try await file.write(from: url) { (completed: Int64, total: Int64, _, _) in
    progress.update(Double(completed) / Double(total))
    return true
}
let size: Int64 = try await client.directorySize("photos")

// After
try await file.write(from: url) { (completed: FileSize, total: FileSize, _, _) in
    progress.update(Double(completed) / Double(total))
    return true
}
let size: FileSize = try await client.directorySize("photos")
```

Things to watch:

- **Subtraction can trap.** `total - completed` was safe to compute in any order with `Int64`; with `UInt64` it stops the
  process when `completed` is larger. Progress callbacks never report more than the total, but arithmetic with your own
  values needs the same care as any unsigned arithmetic (`total.subtractingReportingOverflow(completed)`, or compare
  first).
- **Converting from signed values.** A size that comes from `Int` or `Int64` (`Data.count`, `FileManager` attributes
  outside SwiftSFTP) needs `FileSize(x)`, or `FileSize(clamping: x)` when it can be negative.
- **Negative inputs no longer compile.** `set(size: -1)` was silently ignored and `createZeros(length: -1)` stopped the
  process; neither can be written now. Code that computed such a value at runtime must reject it before converting.
- **Overflow.** The progress `upload` and `download` report never exceeds the total, even when a swarm sends a stripe
  again after a broken connection.
- **Sizes above `Int64.max`.** `FileSize` can hold them, but no filesystem does, and the EXIFKit file handle still
  rejects a write that would end past `Int64.max` and a truncation to more than `Int64.max`, as in 3.24. The
  AVFoundation integration refuses to open a file larger than `Int64.max` (`EOVERFLOW`), because AVFoundation counts in
  `Int64`.

## Multi-connection transfers become `SFTPSwarm`

`multiUpload`, `multiDownload`, and `multiTune` are removed, and with them `ResumeBehavior` and `TransferDirection`. An
`SFTPSwarm` takes their place: a set of connections to one server that stay open and are used as one client. It conforms
to `SFTPClientProtocol`, every operation goes to a free connection, and its `upload` and `download` spread a file larger
than its `smallFileThreshold` over every connection in stripes. See
[Swarms of Connections](UserGuide.md#swarms-of-connections) and
[Transfers over a swarm](UserGuide.md#transfers-over-a-swarm).

| 3.24 | 4.0 |
|------|-----|
| `client.multiUpload(from:to:workers: n, ...)` | `let swarm = try await SFTPSwarm(client, numberOfForksToCreate: n - 1)`, then `swarm.upload(from:to:...)` |
| `client.multiDownload(from:to:workers: n, ...)` | `swarm.download(from:to:...)` |
| `resume: .never` | `resume: false`, the default. An interrupted striped transfer still leaves its temporary file, which the next call with `resume: false` deletes |
| `resume: .ifPossible` | `resume: true` |
| `resume: .discardingProgress` | `resume: false`: the temporary file an earlier attempt left is deleted, and the transfer starts from zero |
| `multiTune(testDirection: .upload, ...)` | `swarm.autoTuneForUpload(localFile:testFilePath:clientCountLimit:maximumBackAndForths:)` |
| `multiTune(testDirection: .download, ...)` | `swarm.autoTuneForDownload(testFilePath:createTestFileIfDoesNotExist:clientCountLimit:maximumBackAndForths:)` |
| The rounds `multiTune` logged to its `logger` | The returned `[Int: Double]`: bytes per second by number of connections |
| The worker count `multiTune` returned | `swarm.clientCount().setNumber`: auto-tune leaves the swarm at the fastest count |

**Before (3.24):**

```swift
let workers = try await client.multiTune(testDirection: .upload, workersMax: 8, testFilePath: probe)
try await client.multiUpload(from: localFile, to: remotePath, workers: workers, resume: .ifPossible) { _, _, _, _ in
    true
}
```

**After (4.0):**

```swift
let swarm = try await SFTPSwarm(client, numberOfForksToCreate: 0)
_ = try await swarm.autoTuneForUpload(
    localFile: sample,          // at least clientCountLimit × stripeSize
    testFilePath: probe,
    clientCountLimit: 8,
    maximumBackAndForths: 2
)
try await swarm.upload(from: localFile, to: remotePath, resume: true) { _, _, _, _ in true }
```

What differs besides the names:

- **A swarm owns its clients.** The client you make it from is closed with the others: close the swarm, not the
  client. Keep the swarm for as long as you need the connections, rather than making one per transfer the way
  `multiUpload` forked its workers per call.
- **Forks that fail are retried, not skipped.** `multiUpload` and `multiDownload` went on silently with the workers that
  could log in. A swarm's initializer retries a failing fork as `SwarmOptions.replaceBrokenConnections` says, then
  closes the forks it made and throws, leaving your client open; `increaseClients(_:)` keeps the connections it could
  make and throws the last error.
- **A broken connection no longer ends the transfer.** The first failing worker ended a multi-worker transfer. A swarm
  takes a broken connection out, replaces it, and sends its stripe again on another connection, up to three times in
  all.
- **Auto-tune searches differently.** It starts at the swarm's current number of connections and only adds connections,
  one at a time, re-measuring a result that looks like a fluke at most `maximumBackAndForths` times; `workersStart`,
  `workersStep`, and `bestOf` have no counterpart. An upload tune uploads a local file you pass, of at least
  `clientCountLimit` stripes of `stripeSize` (8 MiB by default), instead of `testFileSize` random bytes. A download tune
  can create its remote test file with `createTestFileIfDoesNotExist: (create: true, size:)`, where `multiTune` required
  it to exist.
- **Small files move in place.** `multiUpload` wrote every file into a temporary file renamed into place, and
  `multiDownload` without resuming deleted an incomplete destination. A swarm moves a file of `smallFileThreshold` bytes
  or less, 10 MiB by default, in place over one connection, exactly as `SFTPClient` does: an interrupted transfer leaves
  a partial destination, which `resume: true` continues from its current size and `resume: false` refuses with
  `remoteFileAlreadyExists` or `localFileAlreadyExists`. So does a larger file whose destination already exists, with
  `resume: true`. Set `smallFileThreshold` to `0` to send every non-empty file in stripes.
- **Larger files go in stripes.** `multiUpload` and `multiDownload` gave each worker one range of the file. A swarm
  hands out stripes of its `stripeSize`, 8 MiB by default, in order, to whichever connection is free. `bufferSize` keeps
  its meaning, the size of each read and write step; `download`'s default is 512 KiB, where `multiDownload`'s was
  1 MiB.
- **Every striped transfer can be resumed.** It writes into a temporary file beside the destination, `<hash>.rmt.tmp`,
  that carries a version 2 trailer, and renames it onto the destination once complete. An interrupted one leaves its
  temporary file behind whatever `resume` said, where `.never` deleted it, unless nothing from the start of the file had
  arrived. Sweep abandoned ones with `cleanupResumableUploads(in:olderThan:)` and
  `cleanupResumableDownloads(in:olderThan:)`.
- **Partial files from 3.x are not resumed.** The temporary files that `multiUpload` and `multiDownload` wrote with
  `resume: .ifPossible` have the same names, but their trailer, version 1 with a block bitmap, reads as corrupt: the
  next striped transfer to that destination deletes it and starts from zero.
- **The server must shrink files for striped uploads.** A striped upload cuts its trailer off with `SETSTAT`. A server
  that refuses gets `resumableTruncateUnsupported`; a `smallFileThreshold` of `FileSize.max` moves every file in place
  and avoids the truncation.
- **The progress callback no longer holds up a striped transfer.** It is called on a task of its own, in order, with the
  bytes moved since its previous call; the transfer waits for it only between stripes, holding no connection. Returning
  `false` stops the transfer within one stripe per connection. A resumed transfer's first report starts at what the
  partial file held. A transfer in place calls it inline, as `SFTPClient` does.
- **Two striped transfers to one destination are refused.** A second striped upload to a destination that one through
  the same swarm is writing, and a second striped download to a local file that one in the same process is writing,
  throw the new `FileTransferErrors.transferAlreadyInProgress(path:)`. A `switch` over `FileTransferErrors` without a
  `default` no longer compiles until it handles the case.
- `resumableTrailerVersionUnsupported`, `resumableTruncateUnsupported`, and `resumableDestinationNameTooLong` now come
  from a swarm's striped `upload` and `download`. The way past an unsupported trailer version was
  `resume: .discardingProgress`; it is now `resume: false`.

## `upload` and `download` become protocol requirements

For `SFTPClient`, nothing changes at the call site or at runtime. `upload` and `download` take the same parameters,
with the same defaults, and behave as in 3.24: they write the destination directly over the client's one connection,
`resume: true` continues from the destination's current size, `resume: false` refuses an existing destination, and the
progress callback is called inline, before the next chunk. `SFTPClient` has no `smallFileThreshold` or `stripeSize`;
those are properties of a swarm.

What changes is where they are declared. `upload(from:to:resume:bufferSize:permissions:continuation:)` and
`download(from:to:resume:bufferSize:continuation:)` are requirements of `SFTPClientProtocol` now, instead of extension
methods, so a swarm held as `any SFTPClientProtocol` still transfers as a swarm. The shorter forms, which leave out any
of `resume`, `bufferSize`, and `permissions`, are overloads in a protocol extension that call the two requirements with
3.24's defaults: `resume: false`, a `bufferSize` of 8 MiB for an upload and 512 KiB for a download, and the server's
default permissions. Custom conformers must implement both requirements; see
[Custom `SFTPClientProtocol` conformers](#custom-sftpclientprotocol-conformers).

## AVFoundation methods are `async` and take new labels

`makeAsset` and `makePlayerItem` are `async` now: call them with `await`. Their labels change, with the same defaults
and the same 32 KiB minimum for the piece size:

| 3.24 | 4.0 |
|------|-----|
| `at:` | `path:` |
| `readAheadSize:` (8 MiB) | `readAhead:` (8 MiB) |
| `stripeSize:` (2 MiB) | `bufferSize:` (2 MiB) |

`makeAsset`'s `options` parameter and both results are `sending`.

```swift
// Before
let asset = client.makeAsset(at: "/Videos/clip", contentType: .mpeg4Movie, readAheadSize: 16 * 1024 * 1024)

// After
let asset = await client.makeAsset(path: "/Videos/clip", contentType: .mpeg4Movie, readAhead: 16 * 1024 * 1024)
```

The overloads on a `Collection` of clients are removed. Make a swarm and call the same methods on it. An asset made from
any `SFTPSwarmProtocol` gets one worker per connection that takes work when it is created, which it asks the swarm for,
and opens its read handles through the swarm, which spreads them over its connections. On a plain client the methods
stream over its one connection, as before.

```swift
// Before
let clients = [client, try await client.fork(), try await client.fork(), try await client.fork()]
let item = clients.makePlayerItem(at: "/Videos/holiday.mp4")

// After
let swarm = try await SFTPSwarm(client, numberOfForksToCreate: 3)
let item = await swarm.makePlayerItem(path: "/Videos/holiday.mp4")
```

The asset's handles share the swarm's connections with its other operations. A worker whose read failed opens a new
handle when it is next used, and a swarm opens it on a working connection. Keep the swarm open during playback; closing
it under a playing asset is a misuse.

## Custom `SFTPClientProtocol` conformers

Mocks and other types conforming to `SFTPClientProtocol` must:

- make their `init` `async throws`, with the parameters `_ openSocketIn`, `hostKeyAcceptance`, `authentication`,
  `compressionPreference`, `loginTimeOut`, `operationsTimeOut`, and `deinitErrorHandler: @escaping
  DeinitErrorHandler`, in that order, and return logged in;
- add `static func preflightConfigurationCheck(_:hostKeyAcceptance:authentication:)
  throws(SFTPClientInvalidConfig)`;
- remove `login(timeOut:)`, and replace `fork(loggedIn:)` with `fork()`;
- rename `contentsOfDirectory(path:recursive:)` to `listDirectory(path:recursive:)`;
- take `size: FileSize?` instead of `size: Int64?` in `setAttributes(path:size:owner:date:permissions:)`;
- declare `static func getServerHostKey(_:timeOut:)`, without the `openSocketIn` label and the `shortHandForm`
  parameter, and return the
  `known_hosts` line;
- drop any `import Logging` they had only for the protocol;
- implement `upload(from:to:resume:bufferSize:permissions:continuation:)` and
  `download(from:to:resume:bufferSize:continuation:)`, which used to be extension methods with these parameters and
  defaults, built on the conformer's own `stat`, `createDirectory`, and `openFile`. There is no default implementation
  to fall back on. The shorter overloads, which leave out any of `resume`, `bufferSize`, and `permissions`, remain
  extension methods that call these two (see
  [`upload` and `download` become protocol requirements](#upload-and-download-become-protocol-requirements)).

`SFTPFileProtocol` and `SSHShellAgentProtocol` keep their requirements; only their documented errors changed, and the
sizes in `set(size:owner:date:permissions:)`, `createZeros(file:length:)`, and `createRandomData(file:length:)` are
`FileSize` (see [File sizes and offsets are `UInt64`](#file-sizes-and-offsets-are-uint64)).

## Smaller behaviour changes

- `SFTPFile` is now a thin public wrapper around an internal core, which is what outlives a released file until its
  close completes. Its public API is unchanged.
- `operationsTimeOut: .infinity` is normalized to `nil`, as before.
- Layer 0 `SessionSetTimeout(session:timeOut:)` treats `.infinity` and any non-positive value as "no timeout", and waits
  at least one millisecond for a positive value shorter than that, instead of rounding it to zero (no timeout).
- Reading or setting `client.timeout` after `close()` is a misuse: a debug build stops; a release build reads zero or
  ignores the new value.
- The cache's checks against its control connection no longer treat a close that races them as misuse; they fail as
  unanswered checks.
- A directory handle that fails to close while listing is ignored instead of logged.

## Checklist

1. Bump the dependency to `from: "4.0.0"` and raise deployment targets to the new minimums.
2. Add swift-log directly if you still use it; make sure PathWorks resolves to 2.1.0 or later.
3. Remove `trapOnDeInitWithoutClose:`; replace `logger:` with `deinitErrorHandler:` or remove it.
4. Replace `TraceSetToLogger` with `TraceSetHandler` + `Trace`.
5. Replace `SFTPClient(...)` + `login(timeOut:)` and `initAndLogin(...)` with `try await SFTPClient(...)`, moving
   `loginTimeOut` and `operationsTimeOut`, in that order, after `compressionPreference`; replace `fork(loggedIn:)` with `fork()`; use
   `preflightConfigurationCheck` where you created a client only to validate its configuration.
6. Replace `PrivateKeySet`, `PrivateKeyString`, `PrivateKeyFile`, `.privateKeyFile`, and `.privateKeyString` with
   `PrivateKey` and `.privateKey` / `.privateKeys([PrivateKey])`; handle key errors where you create the keys.
7. Replace the `isValid_…` and `isValidForSSH_…` checks on key text with `PrivateKey` / `PublicKey` and `validForSSHAuth`.
8. Rename `contentsOfDirectory` to `listDirectory`.
9. Remove `await cache.close()`; call `removeAll()` where you want the bytes gone at once.
10. Remove `catch` and `switch` cases for `AlreadyClosed`, `NotLoggedIn`, and the removed enum cases; fix any race they
   were hiding. Catch `UserAuthenticationError` where you caught `SFTPClientInvalidConfig.authenticationFailed`.
11. Validate timeouts, keepalive intervals, buffer and chunk sizes, local URLs, private key arrays, and shell agent
    inputs before passing them, since invalid values now stop the process.
12. Handle `ShellAgentError.channelClosedAfterFailure` by opening a new shell agent.
13. Replace `Int64` with `FileSize` in progress callbacks, `directorySize` results, `set(size:)`, `upTo:`, and shell
    agent `length:` arguments, and check unsigned subtraction in your own progress arithmetic.
14. Remove `openSocketIn:` and `shortHandForm:` from `getServerHostKey` calls; rename `.loadFromFile` to
    `.loadKnownHostsFile` and `.loadFromFileString` to `.loadKnownHostsString`, and replace `.shortHandAcceptedKeys`
    with `.loadKnownHostsString`, prefixing keys you stored in the shorthand form with `TCPLocation.knownHostsFormat`.
15. Replace `multiUpload`, `multiDownload`, and `multiTune` with an `SFTPSwarm` and its `upload`, `download`,
    `autoTuneForUpload`, and `autoTuneForDownload`, passing `resume: true` for `.ifPossible` and `resume: false` for
    `.never` and `.discardingProgress`; sweep abandoned temporary files with `cleanupResumableUploads` and
    `cleanupResumableDownloads`.
16. Add `await` to `makeAsset` and `makePlayerItem`, rename `at:` to `path:`, `readAheadSize:` to `readAhead:`, and
    `stripeSize:` to `bufferSize:`; make AVFoundation assets from a swarm instead of a collection of clients.
17. Handle `FileTransferErrors.transferAlreadyInProgress` in exhaustive `switch` statements, and implement
    `upload(from:to:resume:bufferSize:permissions:continuation:)` and
    `download(from:to:resume:bufferSize:continuation:)` in custom `SFTPClientProtocol` conformers.
18. Run your tests in a debug build: any remaining misuse stops at an assertion failure where it happens.
