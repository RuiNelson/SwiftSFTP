# Apple crypto coexistence regression tests

The consumers in this directory are independent packages. They exercise the public
SwiftSFTP product as an application would; adding tests to SwiftSFTP's own test target
would bypass the product linkage boundary.

## Foreign headers and symbols (macOS, no server required)

From the repository root:

```sh
python3 Scripts/generate-libssh2-apple-backend.py --check
bash Tests/Packaging/CryptoIsolation/check-header-isolation.sh
swift test --package-path Tests/Packaging/CryptoIsolation --scratch-path /private/tmp/swiftsftp-crypto-isolation
```

The header check compiles the vendored OpenSSL backend with a deliberately invalid
foreign `openssl/opensslv.h` **first** in the include search path. Apple configuration
must select our framework-qualified adapter before any canonical includes are read.

The consumer statically links a second C implementation of `EVP_PKEY_CTX_new_id`.
SwiftSFTP key generation must succeed without calling it. With automatic/static
SwiftSFTP linkage, the counter is 1 and the generated key is nil; explicit dynamic
linkage keeps these call sites bound to OpenSSLCrypto in their own Mach-O image.
These checks run in Apple CI. They do not establish ELF symbol isolation on Linux/Android.

## Official MEGA artifact (iOS 27)

`MEGACoexistence` consumes MEGA's official, checksum-pinned `libmega_25_12_12`
XCFramework. The URL/checksum are from the upstream MEGA iOS manifest; no binary
or headers are patched. From that package directory, choose an available iOS 27 simulator:

```sh
xcodebuild -scheme MEGACoexistence-Package \
  -destination 'platform=iOS Simulator,id=<simulator-UUID>' \
  -derivedDataPath /private/tmp/swiftsftp-mega-consumer \
  -parallel-testing-enabled NO test
```

The offline test alternates MEGA's SHA-256 of `abc` with SwiftSFTP Ed25519 generation
and private-to-public key round trips 20 times in one process. A bare library build
can hide both a wrong header selection and a wrong symbol provider; this test executes
the linked result.

The optional `sftpDownloadAndMEGACryptoWorkInOneProcess` test additionally logs in to
a read-only OpenSSH fixture on `127.0.0.1`, pins its host key, lists `/`, and reads
`/bytes.bin` in 32 KiB chunks while repeatedly invoking MEGA SHA-256. The complete
payload is hashed through MEGA and compared with the independent fixture hash.
It requires these test-process environment variables (in a test plan or xctestrun;
do not commit credentials):

- `SWIFTSFTP_MEGA_LIVE=1`
- `SFTP_TEST_PORT`, `SFTP_TEST_PASSWORD` (fixture user: `proof`)
- `SFTP_TEST_KEY` (OpenSSH `algorithm base64` host key)
- `SFTP_TEST_SHA256` (hex digest of `bytes(range(251)) * 8356 + b"END"`)

Without the opt-in, the network test is skipped. A live verification must report
**two passing tests with no skips**, not count the offline test alone as network proof.
The fixture has 2,097,359 bytes; writes/uploads and MEGA account access are not exercised.

## Why the generated Apple adapter exists

Xcode puts its shared build-product `include/` directory ahead of private target `-I`
paths. Merely adding a private `openssl/` forwarding tree therefore still permits MEGA
headers to compile libssh2 against BoringSSL while the linker selects OpenSSLCrypto.
`HAVE_CONFIG_H` is scoped to the Apple libssh2 target. Its private configuration preloads
an exact copy of the pinned libssh2 backend with only its 13 OpenSSL include paths
qualified as `OpenSSLCrypto/swiftsftp_openssl/...`. The existing include guard prevents
the subsequent backend include from selecting foreign headers. The submodule is untouched.
The generator's `--check` runs before CI rebuilds can hide a stale committed adapter.

The normal Linux/Android C configuration continues to use the system/backend headers.
The dynamic SwiftSFTP product requires dynamic-library delivery; Xcode handles embedding
for a normal SwiftPM dependency. Platform-specific distribution and real-device checks
remain separate from these simulator and macOS regressions.
