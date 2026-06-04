# Validate login timeout

## Problem

`login(timeOut:)` documents that the timeout must be positive and finite, but the implementation passes the value directly through `timeOut.milliseconds`.

Negative, zero, infinite, or NaN values are not rejected by `login(timeOut:)`.

## Impact

Invalid values can configure libssh2 with unintended timeouts. NaN or infinity may also trap or produce undefined conversion behavior when converted to `Int`.

This differs from `getServerHostKey`, which already rejects invalid timeout values.

## Evidence

- `Sources/SwiftSFTP/SFTPClient/Protocols.swift`: `login(timeOut:)` documents a positive finite timeout.
- `Sources/SwiftSFTP/SFTPClient/SFTPClient.swift`: `login(timeOut:)` calls `SessionSetTimeout(session:timeoutMilliseconds:)` with `timeOut.milliseconds` and does not validate first.
- `Sources/SwiftSFTP/Extensions/TimeInterval.swift`: `milliseconds` converts through `Int((self * 1000).rounded())`.

## Proposed fix

Add the same guard used by `getServerHostKey`:

```swift
guard timeOut > 0, timeOut.isFinite else {
    throw SFTPClientInvalidConfig.invalidTimeOutValue
}
```

Add tests for negative, zero, infinity, and NaN login timeouts.
