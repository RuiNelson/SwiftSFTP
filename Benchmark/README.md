# Benchmarks

Build both executables from the repository root:

```sh
swift build --package-path Benchmark -c release
swift run --package-path Benchmark -c release swift-sftp-benchmark --help
swift run --package-path Benchmark -c release swift-sftp-autotune --help
```

Use release builds for throughput measurements. Both commands require a real SFTP
server; the local fixture is described in
[TestServerInfo.md](../Documentation/TestServerInfo.md).

## `swift-sftp-benchmark`

Uploads and downloads `--file` three times per configuration and reports the
fastest run of each:

- **SwiftSFTP, one connection**: `upload` / `download` on an `SFTPClient`.
- **SwiftSFTP, swarm**: the same calls on an `SFTPSwarm` of `--connections`
  connections, made from that client after the one-connection runs.
- **Citadel**: its SFTP client, writing and reading 512 KiB at a time.

```sh
swift run --package-path Benchmark -c release swift-sftp-benchmark \
    --host sftp.example.com --username alice --password secret \
    --directory /home/alice/benchmark --file ~/random-100MiB.bin --connections 2
```

SwiftSFTP runs with its defaults. The one-connection runs write the destination
in place, as `SFTPClient` always does. The swarm sends a file larger than its
`smallFileThreshold`, 10 MiB by default, in stripes of its `stripeSize`, 8 MiB
by default, through a resumable temporary file, and moves a smaller one in place
over a single connection, so the swarm then has nothing to share. Use a file of
random data, so that compression cannot flatter the result.

## `swift-sftp-autotune`

Makes a swarm of `--connections` connections (one by default) and runs
`autoTuneForUpload` or `autoTuneForDownload`, as `--direction` says, with a test
file of `--size` MiB of random data (256 by default). It prints the throughput
of every connection count it measured and the count the swarm was left at:

```sh
swift run --package-path Benchmark -c release swift-sftp-autotune \
    --host sftp.example.com --username alice --password secret \
    --directory /home/alice/benchmark --direction download \
    --client-count-limit 8 --maximum-back-and-forths 2
```

The test file goes into `--directory` under a random name and is deleted at the
end. Each round moves the file in stripes of the swarm's default `stripeSize`,
8 MiB. Use at least 8 MiB of test file per connection of `--client-count-limit`,
ideally several times that, or the larger counts have too little work to share.

## Notes

The executables use the `SwiftSFTPStatic` product, so SwiftSFTP and its
PathWorks dependency link into them once. The default `SwiftSFTP` product
remains dynamic.

BigInt 5.7.0 (a Citadel dependency) emits a manifest warning with recent Swift
toolchains because it declares watchOS 4 support. Its upstream manifest still
contains that declaration; it does not prevent these macOS executables from building.
