# SwiftSFTP — Block-Level Cache

SwiftSFTP can keep what a client reads from the server so that reading it again costs nothing. This guide walks you
from adding a cache in two lines to replacing parts of it with your own. For the exact contract of each type and
method, see the symbol documentation in the source.

## Table of Contents

1. [Getting started](#getting-started)
2. [How the cache APIs are organized](#how-the-cache-apis-are-organized)
3. [A custom storage backend for `ReferenceCache`](#a-custom-storage-backend-for-referencecache)
4. [A custom cache](#a-custom-cache)

---

## Getting started

Every time you read from a remote file, the bytes cross the network. If your app reads the same bytes again — a photo
browser revisiting thumbnails, a player seeking back, a file you check right after uploading it — a cache lets the
client answer from memory instead.

### Adding an in-memory cache

Create a `ReferenceCache` and attach it to a logged-in `SFTPClient`:

```swift
import SwiftSFTP

let cache = ReferenceCache(configuration: .init())
client.attachCache(cache)
```

Nothing else changes in your code. Files you open, `upload` and `download`, parallel transfers, and the AVFoundation
and EXIF integrations all read through the cache from now on. The first read of a range comes from the server; later
reads of the same range come from memory.

With the default configuration the cache:

- keeps up to 256 MiB of file contents, dropping the least recently used files when it needs room, and gives memory
  back when the system runs short;
- keeps what you write, so reading it back is free;
- forgets a file as soon as it changes through the client — a write, rename, delete, or shell agent command — and
  notices changes made by others the next time the file is opened.

A cache never makes an operation fail. If it has nothing, or runs into trouble, the client simply reads from the
server.

### Choosing how much to keep

To change the memory budget, give the cache its own storage:

```swift
let storage = InMemoryCacheStorage(byteBudget: 64 * 1024 * 1024)
let cache = ReferenceCache(storage: storage, configuration: .init())
```

`InMemoryCacheStorage` also takes a `maximumFileSize`, so that one large video cannot push everything else out.

### Forks, several servers, and closing

Clients forked from a client with a cache attached share that cache, so the connections of a parallel transfer benefit
from each other's reads. A cache belongs to one server: for another server, create another `ReferenceCache`. Caches
for different servers can share one `InMemoryCacheStorage`, and with it one budget.

When you are done, detach the cache and close it:

```swift
client.detachCache()
await cache.close()
```

Closing the client detaches the cache but does not close it, since other clients may still use it.

### A configured cache with a control connection

The defaults trust what the client sees. When files on the server may change while your app has them open, or when
browsing folders feels slow, `ReferenceCache.Configuration` lets you trade a little work for freshness or speed. Some
options need the cache to talk to the server itself, over a **control connection** of its own:

```swift
let control = try await client.fork(loggedIn: true)
let cache = try await ReferenceCache(
    storage: InMemoryCacheStorage(byteBudget: 128 * 1024 * 1024),
    controlConnection: control,
    configuration: .init(
        trustPolicy: .statOnServer,
        revalidationInterval: 10,
        metadata: .answer(for: 5, includingMissing: false),
        resolvesRelativePaths: true
    )
)
client.attachCache(cache)
```

Line by line:

- `client.fork(loggedIn: true)` opens the control connection, a second logged-in connection to the same server. Opening
  it is up to you: fork **before** attaching any cache to the client, so that this connection does not go through a
  cache itself, and use it for nothing else while the cache has it.
- `trustPolicy: .statOnServer` has the cache stat a file on the server before answering from it, so changes made by
  others are noticed even while the file stays open. `revalidationInterval: 10` repeats that check at most every 10
  seconds per file.
- `metadata: .answer(for: 5, includingMissing: false)` answers stats and directory listings from the cache for up to 5
  seconds, which makes browsing faster. Changes made by others can go unnoticed for that long; changes made through the
  client never do.
- `resolvesRelativePaths: true` lets a relative path and an absolute path to the same file share what is cached.

The control connection stays yours: neither closing the client nor `cache.close()` closes it. When done, detach the
cache, close it, then close the connection; close the connection too if the initializer throws:

```swift
client.detachCache()
await cache.close()
try await control.close()
```

Other options, such as hashing files on the server or recognising files reached through symbolic links, are described in the
documentation of `Configuration` and `TrustPolicy`, with what each one costs and guarantees.

---

## How the cache APIs are organized

The cache is made of two decisions, each behind a protocol, so you can replace one and keep the other:

```
SFTPClient
   │  tells the cache what it read, wrote, and changed
   ▼
SFTPBlockLevelReadCache        which bytes are still current        ReferenceCache
   │  keeps bytes in
   ▼
CacheStorage                   where bytes live, how many to keep   InMemoryCacheStorage
```

- **`SFTPClientWithCache`** is how a client takes a cache: `attachCache`, `detachCache`, `hasCacheAttached`.
  `SFTPClient` conforms to it.
- **`SFTPBlockLevelReadCache`** is what the client talks to. The client asks it before reading and tells it about every
  change it makes, but leaves every decision to it: what to keep, and when kept data stops being valid.
- **`ReferenceCache`** is the cache this package ships. It tracks file versions, checks them against the server as
  configured, and handles renames, deletes, and the races between them.
- **`CacheStorage`** is where `ReferenceCache` puts the bytes. It only stores and evicts; it never decides whether
  bytes are current.
- **`InMemoryCacheStorage`** is the storage this package ships.

A few small types travel between them: `CacheRequestID` ties a lookup to the answer that follows it, `CachedFileStat`
is a stat answered by a cache, `CacheBlockSource` says whether bytes were downloaded or uploaded, and `CacheFileID`
names a file's bytes inside a storage.

In practice:

- to change **where** bytes are kept, or **how many**, write a `CacheStorage` and keep `ReferenceCache`;
- to change **what** is kept or **when it is trusted**, write an `SFTPBlockLevelReadCache`.

The first is much smaller and much harder to get wrong. Prefer it whenever it is enough.

---

## A custom storage backend for `ReferenceCache`

Write a `CacheStorage` when memory is the wrong place for the bytes: you want to cache more than RAM allows by keeping
them on disk, or your app already has a store with its own eviction rules. `ReferenceCache` keeps doing the hard part —
deciding what is current — and only asks your storage to hold bytes.

### What `ReferenceCache` expects

Think of your storage as a set of sparse files. For each `CacheFileID`, it holds some byte ranges of a remote file, and
`ReferenceCache` writes ranges, reads them back from a given offset, asks which ranges you hold, and tells you to keep
only some of them or to forget the file.

Besides that, it relies on a few promises:

- **You may forget a file at any time, but only a whole file.** Evict as you like, but never leave holes in a file you
  keep: a file with holes would turn long cached reads into short ones.
- **Answers are immediate.** `ReferenceCache` calls you synchronously from inside its actor. Local disk is fine; the
  network is not.
- **Failure means "nothing held".** Your methods cannot throw. When something goes wrong, forget the file: the cost is
  one download, never wrong bytes. A `write` that fails, or that would not fit, forgets the file and returns `false`.
- **You protect your own state.** Several caches may share your storage, and you may evict from your own threads.
- **`accepts(fileSize:)` is your size limit.** Return `false` for files you would not keep whole, and the cache will not
  try.

### One thing to know before you persist

A `CacheFileID` is unique within the running process only, and `ReferenceCache` creates a new one whenever it starts
tracking a file. A disk storage therefore gives the cache more room, not a longer life: clear it when your app starts.
If you want a cache that survives restarts, that is a policy decision, and it belongs in a custom cache.

### Using it

Pass your storage to `ReferenceCache` in place of `InMemoryCacheStorage`. Everything else stays the same, including
sharing one storage among the caches of several servers.

---

## A custom cache

Write your own `SFTPBlockLevelReadCache` when you know something about your files that a general-purpose cache cannot:
that they are never rewritten in place, that they should survive app restarts, or that some of them should never be
cached at all. Attach it like any other cache, with `attachCache`.

### Start by wrapping

Often you do not need a cache from scratch. A type that conforms to `SFTPBlockLevelReadCache` and forwards to a
`ReferenceCache` can add logging or metrics, or skip certain paths, while `ReferenceCache` keeps the hard parts.

A wrapper may decline to answer a lookup or decline to keep what it is given. It must still forward every report of a
change, and the start and end of every request: the path it skips may be another name for a file the inner cache
holds.

### How the client talks to a cache

The client has two kinds of conversation with a cache.

**Requests.** Before reading, the client asks: `retrieveBlock` for bytes, `retrieveFileStat` and
`retrieveDirectoryListing` for metadata. Each question carries a new `CacheRequestID`. If the cache returns `nil`, or
only part of the bytes, the client asks the server and hands over the answer through the matching `store…` method,
with the same ID. Finally it calls `requestEnded` for that ID, once, however the request went. When the client stats a
file it has open, it opens the request with `beginRequest` instead of a question.

**Reports.** When the client changes something, it tells the cache: `storeBlock` with `.upload` for bytes it wrote,
`didAppend`, `didRename`, and `invalidate` for anything else. `invalidate(path:)` covers the path, everything under it,
and the listing of its parent.

Your cache answers and keeps what it likes. Returning `nil` is always allowed.

### The one thing to get right

Requests and reports overlap. A download can still be on its way when another task renames, deletes, or rewrites the
same file. Its answer then reaches your cache after the change and describes the file as it was before. Keep it, and
your cache will hand out old bytes from then on.

So: **dropping is always safe; keeping needs proof that nothing changed at that path since the request began.** The
simplest proof is a counter that every report increments. Note its value when a request begins, and refuse a store if
it moved. A single counter for the whole cache refuses more than necessary, but it is clearly correct, and a refused
store only costs a later download.

Stats and listings are worth watching even when you never answer them: one that shows a file with a different size or
modification time is your cue to drop what you hold of it.

### Paths

The cache sees paths exactly as the client sends them to the server. The same file can arrive as a relative path, an
absolute path, or through a symbolic link, and the cache cannot tell. If your app reaches a file in more than one way,
either normalize paths yourself or use one form throughout. Compare paths byte for byte: two names that differ only in
Unicode normalization are two different files on the server.

### Talking to the server

A cache that checks files against the server needs a connection of its own. Fork the client **before** attaching your
cache, so that connection does not go through the cache itself, and close it when you close the cache:

```swift
let control = try await client.fork(loggedIn: true)
client.attachCache(MyCache(controlConnection: control))
```

This matters most for a cache that survives restarts: the client reports nothing that happened while your app was not
running, so check what you persisted against the server before you answer from it.
