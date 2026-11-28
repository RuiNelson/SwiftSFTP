# SwiftSFTP — Integrations

SwiftSFTP ships optional products that connect it to other libraries. Each one is a dynamic library that also supplies
the `SwiftSFTP` module, so depend on the integration's product instead of `SwiftSFTP`. For everything else, see the
[User's Guide](UserGuide.md).

## Table of Contents

1. [AVFoundation Playback](#avfoundation-playback)
2. [EXIF Metadata](#exif-metadata)

---

## AVFoundation Playback

Use `.product(name: "SwiftSFTPAVFoundation", package: "SwiftSFTP")` as your target's dependency. It supplies both the
`SwiftSFTP` and `SwiftSFTPAVFoundation` modules in one dynamic library. Import them alongside AVFoundation.
The adapter is available on every platform the package supports that has AVFoundation: macOS 12+, iOS 15+, tvOS 15+,
visionOS, and Mac Catalyst 15+.
The SFTP library remains usable on watchOS, Linux, and Android; the AVFoundation adapter has no API on those platforms.

Pass a client that is already authenticated, or an [`SFTPSwarm`](UserGuide.md#swarms-of-connections) for several
connections to the same server:

```swift
import AVFoundation
import SwiftSFTP
import SwiftSFTPAVFoundation

let swarm = try await SFTPSwarm(client, numberOfForksToCreate: 3)

let player = AVPlayer(playerItem: await swarm.makePlayerItem(path: "/Videos/holiday.mp4"))
player.play()

// Or create an asset for metadata loading, AVAssetReader, or your own player item.
let asset = await swarm.makeAsset(
    path: "/Videos/holiday.mp4",
    options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
)
```

`makeAsset(path:contentType:readAhead:bufferSize:options:)` and
`makePlayerItem(path:contentType:readAhead:bufferSize:)` are available on `SFTPClientProtocol`, so on an `SFTPClient`,
an `SFTPSwarm`, and protocol existentials. Both are `async`: an asset made from any `SFTPSwarmProtocol` gets one worker
per connection that takes work, which it asks the swarm for when the asset is created; one made from any other client
gets one worker. Construction performs no network I/O, and no local media file is created: nothing is opened before
AVFoundation first loads the asset.

### Parallel reads and read-ahead

Each worker opens the file read-only through the client when it first fetches. A swarm opens every handle on the idle
connection with the fewest open handles, which spreads the workers over its connections. The file is fetched in pieces
of `bufferSize` bytes, 2 MiB by default, and each worker fetches whole pieces, so the connections of a swarm transfer
different parts of the file at the same time. Bytes reach AVFoundation as soon as they arrive, so neither the start of
playback nor a seek waits for a whole piece.

The workers also read ahead. They keep the `readAhead` bytes that follow AVFoundation's newest request fetched or in
flight, 8 MiB by default, so playback seldom waits on the network. Seeking moves that window and cancels the prefetches
it leaves behind. An asset holds at most `readAhead + bufferSize` bytes of fetched and in-flight pieces, plus any piece
a request is still waiting on. A `readAhead` of zero fetches only the piece being read.

```swift
let item = await swarm.makePlayerItem(
    path: "/Videos/holiday.mp4",
    readAhead: 32 * 1024 * 1024,
    bufferSize: 4 * 1024 * 1024
)
```

More connections help where one connection cannot fill the link, typically when the round trip to the server is
long. At most about `readAhead / bufferSize + 1` pieces are fetched at once, so with the defaults up to five workers
can be busy. Raise `readAhead` or lower `bufferSize` to keep more connections working. A `bufferSize` below 32 KiB uses
32 KiB.

The media type is inferred from a registered filename extension, ignoring case. Missing or unrecognized extensions
fall back to `.movie`. Specify the format explicitly when needed:

```swift
let asset = await client.makeAsset(path: "/Videos/extensionless", contentType: .mpeg4Movie)
```

### Lifetime and errors

The asset retains its client or swarm, and its handles share the connections with your other operations, as any handle
does. Keep the client or swarm open until playback and metadata loading finish. Releasing the asset, or the player item
holding it, cancels pending requests and asynchronously closes the asset's file handles. The asset holds the client, so
it closes itself once you and every asset have released it; call `close()` yourself only after playback. Closing a
client or swarm under a playing asset is a misuse: a debug build stops, and in a release build the media reads that
follow fail with `ENOTCONN`.

The first failure of any worker fails all of AVFoundation's pending requests, and stops the other workers' fetches.
Later requests try again, the failed worker on a new handle, so a connection that keeps failing fails each of them. A
swarm takes a broken connection out of service, and opens that new handle on another one. Loading failures
are reported through AVFoundation's normal asset loading errors and `AVPlayerItem.status == .failed`. AVFoundation
preserves the mapped POSIX code in its underlying `NSPOSIXErrorDomain` error: `ENOENT` for a missing file, `EACCES` for
denied access, `ENOTCONN` for a closed or unauthenticated client, and `ETIMEDOUT` for a timeout.

---

## EXIF Metadata

Enable SwiftSFTP's `EXIFKit` package trait and use `.product(name: "SwiftSFTPEXIFKit", package: "SwiftSFTP")` as your
target's dependency to read, edit, and remove image metadata with [EXIFKit](https://github.com/RuiNelson/EXIFKit):

```swift
.package(url: "https://github.com/RuiNelson/SwiftSFTP.git", from: "3.24.0", traits: ["EXIFKit"])
```

The trait is disabled by default: packages that don't enable it never resolve or fetch EXIFKit, and the
`SwiftSFTPEXIFKit` module is then empty. In Xcode, enable the trait on the package dependency (Xcode 26.4 or later). The product supplies the `SwiftSFTP` and `SwiftSFTPEXIFKit` modules in
one dynamic library, with EXIFKit linked in. `SwiftSFTPEXIFKit` re-exports EXIFKit, so import it instead of adding
EXIFKit's own product, which would link a second copy. The product builds on every platform SwiftSFTP supports,
including Linux and Android.

EXIFKit follows the offsets inside the image and asks only for the ranges that hold metadata, so a large photo is never
downloaded to read its EXIF. It reads in aligned blocks and merges adjacent ones into one request, so a typical JPEG,
HEIF, JPEG XL, or RAW file needs one to four reads.

### Reading by path

`imageMetadata(path:format:options:)` opens the remote file read-only, reads its metadata, and closes the file before
it returns, also when reading fails:

```swift
import SwiftSFTP
import SwiftSFTPEXIFKit

let metadata = try await client.imageMetadata(path: "/Photos/DSC_0042.NEF")
print(metadata.make, metadata.model, metadata.iso)
let thumbnail = try await metadata.readThumbnail()
```

EXIFKit normally reads the embedded thumbnail only on demand, from the file the metadata came from. Because this call
closes the file, it reads the thumbnail first, when the image has one, and keeps it in the returned metadata with
EXIFKit's `loadingThumbnail()`. That costs one more request, and `readThumbnail()` and edits then work without the
file.

### Reading from an open handle

To read a handle you opened yourself, call `imageMetadata(format:options:)` on it, or the equivalent
`EXIFKit.read(file:format:options:)`. Either way, the handle stays yours to close, and the metadata fetches the
thumbnail from it only if you ask:

```swift
let file = try await client.openFile([.read], path: "/Photos/IMG_0001.HEIC", permissions: [])
let metadata = try await file.imageMetadata(format: .heif)
let thumbnail = try await metadata.readThumbnail()
try await file.close()
```

### Editing and removing metadata

`writeImageMetadata(_:path:to:format:options:synchronizesWithFsync:)` replaces an image's metadata, and
`removeImageMetadata(path:to:format:options:synchronizesWithFsync:)` removes its EXIF. Both work in place, or into
another file when you pass `to:`:

```swift
var metadata = try await client.imageMetadata(path: "/Photos/DSC_0042.NEF")
metadata.setGPSCoordinates(latitude: 38.7223, longitude: -9.1393)
try await client.writeImageMetadata(metadata, path: "/Photos/DSC_0042.NEF")

try await client.removeImageMetadata(path: "/Photos/IMG_0001.HEIC", to: "/Shared/IMG_0001.HEIC")
```

The new image is written to a temporary file next to the destination and then renamed over it with the OpenSSH POSIX
rename extension. A failure therefore leaves the image, and any file already at the destination, as they were, and
removes the temporary file. The result takes the image's permission bits, but not its owner. An edit copies every byte
of the image that is not metadata, so editing a remote image reads all of it once.

An edit copies the embedded thumbnail. Metadata from `imageMetadata(path:)` already holds it; metadata read from a
handle fetches it from that handle, so keep the handle open until the edit returns, or call `loadingThumbnail()` first.

Before the rename, the new image is flushed to stable storage with `fsync@openssh.com`. For servers without that
extension, pass `synchronizesWithFsync: false`: writes are already in the remote file once the server acknowledges
them, and only the flush is skipped.

To edit between handles you opened yourself, call `writeImageMetadata(_:to:format:options:synchronizesWithFsync:)` or
`removeImageMetadata(to:format:options:synchronizesWithFsync:)` on the source handle, or the equivalent
`EXIFKit.write(_:from:to:format:options:synchronizesWithFsync:)` and
`EXIFKit.strip(from:to:format:options:synchronizesWithFsync:)`. Open the destination for reading as well as writing.
EXIFKit truncates it and writes the new image from the start, so a failure there can leave a partial image:

```swift
let destination = try await client.openFile(
    [.read, .write, .create, .truncate],
    path: "/Photos/DSC_0042-edited.NEF",
    permissions: [.ownerRead, .ownerWrite]
)
try await file.writeImageMetadata(metadata, to: destination)
try await destination.close()
```

Passing the same handle as source and destination throws `SFTPFileHandleForEXIFKitError.sameSourceAndDestination`.
Two different handles on one remote file cannot be told apart, so never use them as source and destination of one edit.

### Format and options

The format is detected from the file's contents; pass `format:`, such as `.nef` or `.heif`, to skip detection.

`options` takes EXIFKit's `ReadOptions`. Its `readAheadBytes` is the block size: the conveniences use 128 KiB, twice
EXIFKit's own default, because each read is a network round trip. Larger blocks mean fewer round trips but more bytes
transferred, and 0 reads exact ranges. `maximumMetadataBytes` and `maximumReadOperations` cap what one extraction may
read, which protects against malformed files that point all over a large remote file:

```swift
let metadata = try await client.imageMetadata(
    path: "/Photos/DSC_0042.NEF",
    format: .nef,
    options: ReadOptions(maximumReadOperations: 64, readAheadBytes: 256 * 1024)
)
```

### Lifetime and concurrency

Metadata read from a handle keeps that handle, so that `readThumbnail()` can fetch the thumbnail later and an edit can
copy it. Close the handle only once you no longer need either; a thumbnail read after the handle or its client is
closed is a misuse: a debug build stops, and a release build throws `MisuseError`. To close it early, keep `try await metadata.loadingThumbnail()` instead, which holds the
thumbnail in memory and no longer refers to the handle.

An SFTP handle has one read/write position, while EXIFKit reads independent parts of a file concurrently. The adapter
therefore runs the operations on each handle one at a time, each seek together with the reads or the write it positions,
also when the metadata's thumbnail and an edit use the same handle at once. It asks libssh2 to read ahead only to the
end of each range. Don't use the handle for anything else while EXIFKit works with it.

### Errors

SFTP failures surface unchanged: for example, `FileTransferErrors.remoteFileNotFound(path:)` when the path does not
exist, and the `MisuseError` a read throws in a release build after the handle or client is closed. Ranges past the end throw EXIFKit's
`FileAccessError.invalidRange(offset:count:size:)`, a file that ends before its reported size throws
`FileAccessError.shortRead(expected:actual:)`, and a server that omits the file size from its attributes throws
`SFTPFileHandleForEXIFKitError.sizeUnavailable`. Files EXIFKit cannot parse, and edits a format cannot hold, such as
EXIF too large for a JPEG, throw EXIFKit's own errors.
