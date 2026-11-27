# Migrating from SwiftSFTP 3.24 to 4.0

SwiftSFTP 4.0 changes how the library reports problems and how objects are released. Most programs need only a few
mechanical edits; the compiler finds nearly all of them. This guide lists every source-breaking change and every change
in runtime behaviour, with what to do about each.

## At a glance

| 3.24 | 4.0 |
|------|-----|
| macOS 11, iOS 14, tvOS 14, watchOS 7, Mac Catalyst 14 | macOS 12, iOS 15, tvOS 15, watchOS 9, Mac Catalyst 15 |
| Depends on swift-log | No logging dependency; SwiftSFTP logs nothing |
| `logger:` and `trapOnDeInitWithoutClose:` parameters | `deinitErrorHandler:` parameter |
| `close()` required on clients, files, and shell agents | `close()` optional: a released object closes itself |
| `SFTPClient(...)` then `login(timeOut:)`, or `initAndLogin(...)` | `try await SFTPClient(...)`: the initializer logs in |
| `fork(loggedIn:)` | `fork()`, always logged in |
| Configuration checked by the synchronous `init` | `preflightConfigurationCheck(openSocketIn:hostKeyAcceptance:authentication:)` |
| `AlreadyClosed`, `NotLoggedIn` thrown | Misuse: assertion failure in debug, `MisuseError` thrown in release; no "not logged in" state |
| Invalid timeouts, buffer sizes, keepalive intervals, URLs thrown or ignored | Precondition failure in every build |
| `.privateKeys(PrivateKeySet)`, `.privateKeyFile`, `.privateKeyString` | `.privateKey(PrivateKey)`, `.privateKeys([PrivateKey])` |
| `contentsOfDirectory(path:recursive:)` | `listDirectory(path:recursive:)`, returning `[FileMetadata]` |
| Deprecated `listDirectory(path:recursive:) -> Set<FileMetadata>` | Removed; the name now returns `[FileMetadata]` |
| `multiTune(..., logger:)` | `multiTune(..., onRound:)` with `MultiTuneRound` |
| `TraceSetToLogger(session:options:)` | Removed; use `TraceSetHandler` and `Trace` |
| `ReferenceCache.close()` | Removed; release the cache, or call `removeAll()` |
| Deprecated `SwiftSFTP_Curve25519`, `OpenSSHKeyPair` | Removed; use `AsymmetricCryptography.EdDSA.Ed25519` with `PrivateKey` and `PublicKey` |
| `SFTPClientInvalidConfig.authenticationFailed(_:)` | `UserAuthenticationError` |

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
    openSocketIn: location,
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

`multiTune` takes an `onRound` callback instead of a `logger`. It receives each timed round as a `MultiTuneRound`, with
`search`, `workers`, `bytes`, `duration`, and `bytesPerSecond`.

```swift
// Before
let workers = try await client.multiTune(testDirection: .upload, testFilePath: probe, logger: logger)

// After
let workers = try await client.multiTune(testDirection: .upload, testFilePath: probe) { round in
    logger.info("\(round.workers) worker(s): \(round.bytesPerSecond / 1_048_576) MiB/s")
}
```

The per-search and final summary lines the logger used to print are not reported separately: keep the fastest round
yourself if you need them, or use the returned worker count.

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
- `loginTimeOut` (default `10.0`) is new, after `compressionPreference`, and `operationsTimeOut` moves after it. The
  parameter order is now `openSocketIn`, `hostKeyAcceptance`, `authentication`, `compressionPreference`,
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
    openSocketIn: location,
    hostKeyAcceptance: .loadFromFile(file: knownHosts),
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
`SFTPClient.preflightConfigurationCheck(openSocketIn:hostKeyAcceptance:authentication:)` instead. It runs the checks the
initializer runs before connecting — hostname, port, username, authentication material, and host-key acceptance data,
loaded into a libssh2 session that it then frees — and throws `SFTPClientInvalidConfig`:

```swift
// Before
_ = try SFTPClient(openSocketIn: location, hostKeyAcceptance: acceptance, authentication: auth)

// After
try SFTPClient.preflightConfigurationCheck(openSocketIn: location, hostKeyAcceptance: acceptance, authentication: auth)
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
- **AVFoundation**: closing a client under a playing `SFTPAsset` is a misuse. Keep every client open until playback and
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
| Shell agent | Negative length to `createZeros`, `createRandomData` | Threw `ShellAgentError.invalidArgument` | Precondition failure |

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
| `PrivateKeyString` / `PrivateKeyFile` `.valid`, `.isValidForSSH`, `.algorithm` | `String.isValid_PrivateKey(passphrase:)`, `String.isValidForSSH_PrivateKey(passphrase:)`, `SSHUserKeyAlgorithm(privateKey:)` |

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

## Custom `SFTPClientProtocol` conformers

Mocks and other types conforming to `SFTPClientProtocol` must:

- make their `init` `async throws`, with the parameters `openSocketIn`, `hostKeyAcceptance`, `authentication`,
  `compressionPreference`, `loginTimeOut`, `operationsTimeOut`, and `deinitErrorHandler: @escaping
  DeinitErrorHandler`, in that order, and return logged in;
- add `static func preflightConfigurationCheck(openSocketIn:hostKeyAcceptance:authentication:)
  throws(SFTPClientInvalidConfig)`;
- remove `login(timeOut:)`, and replace `fork(loggedIn:)` with `fork()`;
- rename `contentsOfDirectory(path:recursive:)` to `listDirectory(path:recursive:)`;
- drop any `import Logging` they had only for the protocol.

`SFTPFileProtocol` and `SSHShellAgentProtocol` keep their requirements; only their documented errors changed.

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
4. Replace `multiTune(..., logger:)` with `onRound:`, and `TraceSetToLogger` with `TraceSetHandler` + `Trace`.
5. Replace `SFTPClient(...)` + `login(timeOut:)` and `initAndLogin(...)` with `try await SFTPClient(...)`, moving
   `loginTimeOut` and `operationsTimeOut`, in that order, after `compressionPreference`; replace `fork(loggedIn:)` with `fork()`; use
   `preflightConfigurationCheck` where you created a client only to validate its configuration.
6. Replace `PrivateKeySet`, `PrivateKeyString`, `PrivateKeyFile`, `.privateKeyFile`, and `.privateKeyString` with
   `PrivateKey` and `.privateKey` / `.privateKeys([PrivateKey])`; handle key errors where you create the keys.
7. Rename `contentsOfDirectory` to `listDirectory`.
8. Remove `await cache.close()`; call `removeAll()` where you want the bytes gone at once.
9. Remove `catch` and `switch` cases for `AlreadyClosed`, `NotLoggedIn`, and the removed enum cases; fix any race they
   were hiding. Catch `UserAuthenticationError` where you caught `SFTPClientInvalidConfig.authenticationFailed`.
10. Validate timeouts, keepalive intervals, buffer and chunk sizes, local URLs, private key arrays, and shell agent
    inputs before passing them, since invalid values now stop the process.
11. Handle `ShellAgentError.channelClosedAfterFailure` by opening a new shell agent.
12. Run your tests in a debug build: any remaining misuse stops at an assertion failure where it happens.
