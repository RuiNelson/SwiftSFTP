# Resumable transfer details

How progress is stored for `multiUpload` / `multiDownload` with `resume: .ifPossible`, what survives an interruption, what is not protected, and how workers relate to progress.

See also [Resumable parallel transfers](UserGuide.md#resumable-parallel-transfers) in the User's Guide.

## How the progress is remembered

The bytes go into a temporary file in the destination's own directory, named `<hash>.rmt.tmp`, where the hash is the
first 128 bits of the SHA-256 of the destination's file name, in Base32 Crockford (26 characters). Past the end of the payload — starting at the byte the
finished file will end at — the same file carries a trailer holding the final file name, the payload size, the
source's modification time, and a bitmap with one bit per block. There is no database and no separate state file:
everything a resume needs is inside the file it is resuming, and because the temporary's name is derived from the
destination's name, the next call finds its own partial without being told where it is.

When the last block arrives, the trailer is truncated away, the truncation is verified with a `stat`, and only then is
the file renamed onto the destination — which therefore never exists in a partial state. A resumable download is
atomic in this way too, unlike `multiDownload`, which writes to `localURL` directly.

Blocks are sized automatically from the payload size and the requested worker count: 10 MiB at most, and larger only
above roughly 2.5 TiB, where the bitmap has to stay within a single 32 KiB write. The count is always a multiple of
the worker count, because blocks are handed out whole and an uneven count would leave one worker moving a last block
alone while the others are idle. Block size is not configurable, and
on a resume the size recorded in the trailer wins over any later change to `workers`, since recomputing it would
invalidate the bitmap already in the file. Within a block the transfer still moves `bufferSize` bytes at a time.

A block's bit is set only after that block's last write has been acknowledged by the destination, and the bitmap is
written back every two seconds rather than after every block. The record of what has arrived therefore always lags the
data and never leads it. An interruption costs re-transferring the blocks that were in flight, plus — after a crash or
a kill, which cannot flush — those completed since the last bitmap write. Bits only ever go from 0 to 1, so even a
bitmap write cut in half by a crash leaves a valid, pessimistic map.

## What survives an interruption, and what does not

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

`.discardingProgress` deletes any existing temporary file before it is even read. It is both the clean-slate switch
and the only way past a partial file written by a newer release of the library:

```swift
try await client.multiUpload(
    from: localFile,
    to: "/home/alice/backups/archive.zip",
    workers: 4,
    resume: .discardingProgress    // discard any partial file unread, and start from zero
) { _, _, _, _ in true }
```

## What is not protected

> **Warning: two concurrent transfers to the same destination corrupt each other.** Two processes, two machines, or
> two calls inside one process transferring to the same destination derive the same temporary file name and interleave
> their blocks into it. The file that eventually gets published is a mixture of both, and neither call notices.
> Nothing in the library prevents this — no lock file, no ownership marker — so serialize such transfers yourself.
> This is a known gap, to be addressed in a later version.

> **Warning: a source changed while keeping both its size and its modification time resumes as if unchanged.**
> Identity is name, size, and mtime, never a hash of the content. A file restored by a tool that preserves timestamps,
> or rewritten in place within the same second at the same length, passes the check, and the published file is part
> old content and part new. Closing that window would mean reading every byte of the source before transferring any of
> it. Where it matters, pass `resume: .discardingProgress` or verify the result yourself.

A network failure is an error, not a pause: the call throws, the partial file is preserved as long as at least one
block completed, and resuming means calling the method again.

One case remains where the bitmap can be optimistic: a server that acknowledges writes and then loses them, by
crashing with data still in its cache. The library cannot detect it. A single `fsync` is issued before the final
truncation, and its failure is ignored, because not every server implements the extension.

## Connections, workers, and progress

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
