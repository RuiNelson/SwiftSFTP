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
The adapter is available on macOS 11+, iOS 14+, tvOS 14+, visionOS, and Mac Catalyst 14+.
The SFTP library remains usable on watchOS, Linux, and Android; the AVFoundation adapter has no API on those platforms.

Pass clients that are already authenticated. Forks of one client give you more connections to the same server:

```swift
import AVFoundation
import SwiftSFTP
import SwiftSFTPAVFoundation

var clients = [client]
for _ in 1 ..< 4 {
    try await clients.append(client.fork())
}

let player = AVPlayer(playerItem: clients.makePlayerItem(at: "/Videos/holiday.mp4"))
player.play()

// Or create an asset for metadata loading, AVAssetReader, or your own player item.
let asset = clients.makeAsset(
    at: "/Videos/holiday.mp4",
    options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
)
```

`makeAsset(at:contentType:readAheadSize:stripeSize:options:)` and
`makePlayerItem(at:contentType:readAheadSize:stripeSize:)` are available on any collection of clients, such as
`[SFTPClient]`. The same methods on `SFTPClientProtocol`, including `SFTPClient` and protocol existentials, stream over
that one client. A collection must hold at least one client and no client twice. An empty collection or a repeated
client is a programming error and stops at a precondition. Construction performs no network I/O, and no local media
file is created.

### Striping and read-ahead

When AVFoundation first loads the asset, every client opens the file read-only on its own connection. The file is
split into stripes of `stripeSize` bytes, 2 MiB by default, and each client fetches whole stripes. The connections
therefore transfer different parts of the file at the same time. Bytes reach AVFoundation as soon as they arrive, so
neither the start of playback nor a seek waits for a whole stripe.

The clients also read ahead. They keep the `readAheadSize` bytes that follow AVFoundation's newest request fetched or
in flight, 8 MiB by default, so playback seldom waits on the network. Seeking moves that window and cancels the
prefetches it leaves behind. An asset holds at most `readAheadSize + stripeSize` bytes of fetched and in-flight
stripes, plus any stripe a request is still waiting on. A `readAheadSize` of zero fetches only the stripe being read.

```swift
let item = clients.makePlayerItem(
    at: "/Videos/holiday.mp4",
    readAheadSize: 32 * 1024 * 1024,
    stripeSize: 4 * 1024 * 1024
)
```

More connections help where one connection cannot fill the link, typically when the round trip to the server is
long. At most about `readAheadSize / stripeSize + 1` stripes are fetched at once, so with the defaults up to five
clients can be busy. Raise the read-ahead or lower the stripe size to keep more connections working. Stripes smaller
than 32 KiB are rounded up to 32 KiB.

The media type is inferred from a registered filename extension, ignoring case. Missing or unrecognized extensions
fall back to `.movie`. Specify the format explicitly when needed:

```swift
let asset = client.makeAsset(at: "/Videos/extensionless", contentType: .mpeg4Movie)
```

### Lifetime and errors

The asset retains its clients and shares their connections with your other operations. Keep every client logged in
and open until playback and metadata loading finish. Releasing the asset, or the player item holding it, cancels
pending requests and asynchronously closes the asset's file handles. It does not close the clients: you created the
forks, so you close them. Closing a client yourself makes subsequent media reads fail.

The first failure on any client fails all of AVFoundation's pending requests, as a multi-worker download stops at its
first failing worker. Later requests try again, so a client that keeps failing fails each of them. Loading failures
are reported through AVFoundation's normal asset loading errors and `AVPlayerItem.status == .failed`. AVFoundation
preserves the mapped POSIX code in its underlying `NSPOSIXErrorDomain` error: `ENOENT` for a missing file, `EACCES` for
denied access, `ENOTCONN` for a closed or unauthenticated client, and `ETIMEDOUT` for a timeout.

---

## EXIF Metadata

Use `.product(name: "SwiftSFTPEXIFKit", package: "SwiftSFTP")` as your target's dependency to read, edit, and remove
image metadata with [EXIFKit](https://github.com/RuiNelson/EXIFKit). The product supplies the `SwiftSFTP` and `SwiftSFTPEXIFKit` modules in
one dynamic library, with EXIFKit linked in. `SwiftSFTPEXIFKit` re-exports EXIFKit, so import it instead of adding
EXIFKit's own product, which would link a second copy. Like EXIFKit, the product requires macOS 12+, iOS 15+, tvOS 15+,
or watchOS 8+, and it also works on visionOS, Mac Catalyst, and Linux. On Android the module is empty.

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
closed throws `AlreadyClosed`. To close it early, keep `try await metadata.loadingThumbnail()` instead, which holds the
thumbnail in memory and no longer refers to the handle.

An SFTP handle has one read/write position, while EXIFKit reads independent parts of a file concurrently. The adapter
therefore runs the operations on each handle one at a time, each seek together with the reads or the write it positions,
also when the metadata's thumbnail and an edit use the same handle at once. It asks libssh2 to read ahead only to the
end of each range. Don't use the handle for anything else while EXIFKit works with it.

### Errors

SFTP failures surface unchanged: for example, `FileTransferErrors.remoteFileNotFound(path:)` when the path does not
exist, and `AlreadyClosed` after the handle or client is closed. Ranges past the end throw EXIFKit's
`FileAccessError.invalidRange(offset:count:size:)`, a file that ends before its reported size throws
`FileAccessError.shortRead(expected:actual:)`, and a server that omits the file size from its attributes throws
`SFTPFileHandleForEXIFKitError.sizeUnavailable`. Files EXIFKit cannot parse, and edits a format cannot hold, such as
EXIF too large for a JPEG, throw EXIFKit's own errors.
