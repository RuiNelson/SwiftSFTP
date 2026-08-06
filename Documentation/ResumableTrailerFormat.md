# Resumable trailer format

Wire format of the trailer that `multiUpload` / `multiDownload` write with `resume: .ifPossible`. Enough to implement a
compatible reader or writer. For what the feature does and what it does not protect, see
[Resumable transfer details](ResumableTransferDetails.md).

Current version: **1**.

## Temporary file name

```
<hash>.rmt.tmp
```

`<hash>` is the first 16 bytes of the SHA-256 of the destination's **last path component**, encoded in Base32 with the
Crockford alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`, uppercase, no padding, RFC 4648 bit order. That is 26 characters,
34 with the suffix. The file lives in the destination's own directory.

## File layout

```
+---------------------------+  offset 0
|          payload          |
+---------------------------+  offset = fileSize
|      magic word (10)      |
+---------------------------+
|         metadata          |
+---------------------------+
|          bitmap           |
+---------------------------+  end of file
```

The trailer runs to the very end of the file, with no slack after it. At every moment:

```
totalFileSize == fileSize + 10 + metadataByteCount + bitmapByteCount
```

The payload region is preallocated to `fileSize` when the file is created, so the file's size never changes during a
transfer.

## Magic word

Ten bytes: `04 53 77 69 66 74 53 46 54 50` — `EOT` followed by `SwiftSFTP` in ASCII. It sits at file offset `fileSize`.

## Metadata

A sequence of fields, each:

```
key (UInt16) [ length (UInt16) ] value
```

The `length` is present **only** for variable-length fields. All integers are big-endian.

| Key | Field | Length | Type | Value |
|-----|-------|--------|------|-------|
| `0x0001` | Version | omitted | `UInt16` | Trailer format version |
| `0x0002` | File name | `UInt16` | UTF-8 | Final file name, last path component only, no terminator |
| `0x0003` | Payload size | omitted | `UInt64` | Bytes, excluding the trailer. Also the magic word's offset |
| `0x0004` | Block scale | omitted | `UInt64` | Bytes of payload per bitmap bit |
| `0x0005` | Source mtime | omitted | `UInt64` | Whole seconds since 1970-01-01 UTC |
| `0xFFFF` | End of metadata | omitted | — | No length, no value. The bitmap starts on the next byte |

Rules:

- All six keys are mandatory and each appears exactly once. A missing, repeated, or unknown key is corruption.
- Because fixed-length fields omit their length, an unknown key cannot be skipped. This is why the version is rejected
  first, and why a future format must bump the version rather than add fields silently.
- Field order is not fixed, but a writer emits the version first so a reader can reject an unknown format before
  interpreting anything after it.
- A file name longer than 4096 bytes is rejected on read, and refused on write with
  `FileTransferErrors.resumableDestinationNameTooLong`.

## Bitmap

One bit per block, **MSB first**: block 0 is `0x80` of byte 0, block 1 is `0x40`, block 8 is `0x80` of byte 1.

```
blockCount      = ceil(fileSize / blockScale)
bitmapByteCount = ceil(blockCount / 8)
```

- `1` means the block is on the destination. `0` means it is not, or that it is but the bitmap has not caught up yet;
  both are treated as not transferred.
- Unused bits in the final byte are zero on write and ignored on read.
- Bits only ever go from 0 to 1. A bitmap write cut short by a crash therefore leaves a mix of new prefix and old
  suffix, which is still a valid, pessimistic bitmap.
- `blockCount` may not exceed **262 144**, so a full bitmap fits one 32 KiB SFTP write.
- The last block is short when `fileSize` is not a multiple of `blockScale`: it covers
  `fileSize - (blockCount - 1) * blockScale` bytes.

## Block scale

Chosen once, when the temporary file is created, from the payload size and the requested worker count:

```
rounds     = max(1, ceil(fileSize / (10 MiB × workers)))
blockCount = min(rounds × workers, 262144)
blockScale = roundUpToMultipleOf8(max(1, ceil(fileSize / blockCount)))
```

| Payload | Workers | Scale | Blocks | Bitmap |
|---------|---------|-------|--------|--------|
| 100 B | 4 | 32 B | 4 | 1 byte |
| 8 MiB | 4 | 2 MiB | 4 | 1 byte |
| 100 MiB | 3 | 8 738 136 B | 12 | 2 bytes |
| 1 GiB | 8 | 10 324 448 B | 104 | 13 bytes |
| 4 TiB | 8 | 16 MiB | 262 144 | 32 KiB |

The block count is deliberately a multiple of the worker count. Blocks are handed out whole, so a count that does not
divide evenly leaves one worker moving a final block alone while the others sit idle; on a 100 MiB upload over three
workers that cost 20% of the wall clock before this rule was introduced.

10 MiB is the largest a block gets, which bounds how much in-flight work a crash discards. That ceiling gives way only
above roughly 2.5 TiB, where the 262 144-block limit forces a larger scale so the bitmap still fits one 32 KiB write.

On a resume the scale recorded in the trailer is used as-is, whatever `workers` is passed, because recomputing it would
invalidate the existing bitmap.

## Reading a trailer

The magic word only marks where validation starts; it is not proof on its own.

1. `stat` the file for `totalFileSize`.
2. Read the last `min(totalFileSize, 65536)` bytes.
3. Scan that window **backwards** for the magic word.
4. For each candidate at absolute offset `o`, accept only if all hold:
   - the metadata parses under the rules above;
   - field `0x0003` equals `o`;
   - `o + 10 + metadataByteCount + bitmapByteCount == totalFileSize`, where `bitmapByteCount` is what `0x0003` and
     `0x0004` imply;
   - `blockScale > 0` and `blockCount <= 262144`.
5. If no candidate validates, the file is corrupt.

A 64 KiB window always suffices: the largest possible trailer is 36 914 bytes (10 magic + 4 136 metadata with a
4096-byte name + 32 768 bitmap).

Checking `0x0003 == o` alongside the size equation is what makes a magic word occurring inside payload data harmless.

## Writing a trailer

Order matters. When creating a new temporary file:

1. Create it exclusively and preallocate to `fileSize + trailerByteCount`.
2. Write the metadata and the all-zero bitmap.
3. Write the magic word **last**.
4. Only then start transferring.

A crash between steps 1 and 3 leaves a file with no magic word, which reads as corrupt and is deleted — costing nothing,
since no block had been transferred.

During a transfer only the bitmap is rewritten, at offset `fileSize + 10 + metadataByteCount`. The magic word and the
metadata are written once and never touched again.

On completion the file is truncated to `fileSize`, the truncation is verified by `stat`, and only then is the file
renamed onto the destination.

## Version handling

| Condition | Result |
|-----------|--------|
| version `== 1` | Resume normally |
| version `> 1` | Throw `FileTransferErrors.resumableTrailerVersionUnsupported`; the file is **preserved** |
| version `== 0`, or any corruption | Delete the file and restart, silently |

Version 0 was never written by any release, so it is treated as damage rather than as an unsupported format.
`resume: .discardingProgress` deletes the file before reading it, which is the way past a trailer from a newer release.

## Worked example

A 12 MiB payload named `payload.bin`, one worker, one of two blocks transferred:

| Region | Offset | Bytes |
|--------|--------|-------|
| Payload | 0 | 12 582 912 |
| Magic word | 12 582 912 | 10 |
| Metadata | 12 582 922 | 51 |
| Bitmap | 12 582 973 | 1 |
| **Total** | | **12 582 974** |

Metadata: version 4, file name 4 + 11, payload size 10, block scale 10, mtime 10, terminator 2 = 51.
Block scale is 6 MiB, so `blockCount` is 2 and the bitmap is `0x80` — block 0 done, block 1 not.
