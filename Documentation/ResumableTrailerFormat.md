# Resumable trailer format

Wire format of the trailer that an `SFTPSwarm` writes into the temporary file of an upload or download larger than its
`smallFileThreshold`, which it sends in stripes. Enough to implement a compatible reader or writer.

Nothing else writes it. `SFTPClient`, and a swarm's files up to `smallFileThreshold`, move in place: straight into the
destination, without a temporary file or a trailer, and `resume: true` continues from the destination's current size.

Current version: **2**. Version 1, written by the multi-worker transfers of SwiftSFTP 3.x, is not compatible: a version 2
reader sees a version 1 partial file as corrupt, replaces it, and the transfer starts over.

## Temporary file name

```
<hash>.rmt.tmp
```

`<hash>` is the first 16 bytes of the SHA-256 of the destination's **last path component**, encoded in Base32 with the
Crockford alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`, uppercase, no padding, RFC 4648 bit order. That is 26 characters,
34 with the suffix. The file lives in the destination's own directory: on the server for an upload, on disk for a
download.

A transfer with `resume: true` continues the partial file it finds there; with `resume: false` it deletes it and starts
over.

## File layout

```
+---------------------------+  offset 0
|          payload          |  payloadSize bytes, preallocated
+---------------------------+  offset payloadSize
|  magic word "SwiftSFTP"   |  9 bytes
+---------------------------+
|          frames           |
+---------------------------+
|         end frame         |  12 bytes
+---------------------------+  end of file
```

Once every byte has arrived, the writer marks the whole payload valid, truncates the file to `payloadSize`, checks that
the truncation took effect, and renames the file onto the destination. A server that ignores a shrinking `SETSTAT`
leaves a partial file whose whole payload is valid; the next run only has to finish it.

## Magic word

The nine ASCII bytes `SwiftSFTP` (`53 77 69 66 74 53 46 54 50`).

## Frames

Every frame, the end frame included, is:

```
type   UInt16, big-endian
length UInt16, big-endian: the byte count of value
value  length bytes
```

| Type     | Name                     | Value                                                                   |
|----------|--------------------------|-------------------------------------------------------------------------|
| `0x0001` | Version                  | `UInt16`, big-endian: `2`                                               |
| `0x0002` | File name                | UTF-8, the destination's last path component, at most 4096 bytes       |
| `0x0003` | Payload size             | `UInt64`, big-endian: bytes before the magic word                       |
| `0x0004` | Source modification time | `Int64`, big-endian: nanoseconds since 1970-01-01 UTC                   |
| `0x0005` | Valid prefix             | `UInt64`, big-endian: bytes from offset 0 known to be on the destination |
| `0xFFFF` | End                      | `UInt64`, big-endian: the trailer's byte count, magic word included    |

Writers emit the frames in the order of the table, each once. Readers accept them in any order, and skip frame types they
do not know, which is what every frame carrying a length buys. A known type that appears twice, or whose value has the
wrong size, is corruption. The end frame is always last, and its value lets a reader find the trailer from the end of
the file.

The source modification time of an upload is the local file's, to the nanosecond the platform reports. SFTP reports a
remote file's in whole seconds, so a download records that number of seconds times 10⁹.

## Valid prefix

Stripes go out lowest offset first, each to whichever connection is free. A partial transfer therefore has its holes
near the end of the payload, and one number says how much of it can be trusted: every byte before the valid prefix has
been acknowledged by the destination. Bytes past it may have arrived too; a resumed transfer sends them again.

The writer updates the valid prefix in place by rewriting the eight bytes of its value. With the frames in the table's
order, that value sits at a fixed offset, `payloadSize + trailerByteCount - 20`, for the whole transfer. An update is
written only after the writes of every stripe it covers have been acknowledged, only when the prefix grew, and at most
once a second. A transfer stopped by its caller writes the prefix it reached before returning; one that fails on a
broken connection does not, and the next run sends again what the last update did not cover.

A reader trusts the valid prefix and nothing else.

## Reading a trailer

1. Read the last `min(fileSize, 16384)` bytes of the file.
2. The last 12 bytes must be an end frame: `FF FF 00 08` and a `UInt64` byte count. The byte count must be at least 21
   (magic word and end frame) and fit in what was read.
3. The trailer starts that many bytes before the end of the file, with the magic word.
4. Walk the frames after the magic word up to the end frame, which must end exactly at the end of the file.
5. The version frame must be present. A version other than 2 is **not** corruption: the file is kept and the transfer
   reports `resumableTrailerVersionUnsupported`.
6. File name, payload size, source modification time and valid prefix must be present. The payload size must equal
   `fileSize - trailerByteCount`, and the valid prefix must not exceed it.

Anything else that fails is corruption: the reader deletes the file and starts over. A payload that happens to contain
the magic word cannot pass for a trailer, because the end frame, not a search, says where the trailer starts.

A partial file is continued only when its file name, payload size and source modification time all equal the source's
as it is now. Otherwise it belongs to another transfer, and it is deleted.

## Writing a trailer

1. Create the temporary file exclusively and preallocate it to `payloadSize + trailerByteCount`.
2. Write the trailer without its magic word at `payloadSize + 9`, then the magic word at `payloadSize`. Dying between the
   two leaves a file without a magic word, which reads as corrupt, and no stripe had been sent yet.
3. Send the stripes, updating the valid prefix as described above.
4. Write a valid prefix equal to `payloadSize`, truncate the file to `payloadSize`, check its size, and rename it onto
   the destination.

## Worked example

A trailer for `a.bin`, with a payload of 20 bytes, a source modification time of 1 700 000 000.123456789 s after the
epoch, and a valid prefix of 8 bytes. It is 72 bytes long and starts at offset 20 of a 92-byte file. Its valid prefix
value sits at offset 72.

```
53 77 69 66 74 53 46 54 50                         "SwiftSFTP"
00 01 00 02 00 02                                  version 2
00 02 00 05 61 2E 62 69 6E                         file name "a.bin"
00 03 00 08 00 00 00 00 00 00 00 14                payload size 20
00 04 00 08 17 97 9C FE 3D 85 CD 15                modification time 1700000000123456789 ns
00 05 00 08 00 00 00 00 00 00 00 08                valid prefix 8
FF FF 00 08 00 00 00 00 00 00 00 48                end: trailer of 72 bytes
```
