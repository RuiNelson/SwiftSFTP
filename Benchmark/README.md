# Benchmarks

Build both executables from the repository root:

```sh
swift build --package-path Benchmark -c release
swift run --package-path Benchmark -c release swift-sftp-benchmark --help
swift run --package-path Benchmark -c release swift-sftp-multitune --help
```

Use release builds for throughput measurements. Both commands require a real SFTP
server; the local fixture is described in
[TestServerInfo.md](../Documentation/TestServerInfo.md).

The executables use the `SwiftSFTPStatic` product so SwiftSFTP, Citadel and the
command-line logger share one linked copy of `Logging`. The default `SwiftSFTP`
product remains dynamic.

BigInt 5.7.0 (a Citadel dependency) emits a manifest warning with recent Swift
toolchains because it declares watchOS 4 support. Its upstream manifest still
contains that declaration; it does not prevent these macOS executables from building.
