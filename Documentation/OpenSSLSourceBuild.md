# OpenSSL source builds

SwiftSFTP ships source code only. `OpenSSLCrypto` is a native SwiftPM C target built
from `Sources/OpenSSLCrypto/`, and libssh2 is compiled from its pinned submodule.
There are no binary targets, packaged XCFrameworks, or separate OpenSSL dylibs. The
dynamic SwiftSFTP product contains libcrypto and is signed by the consuming app's
normal build. No SDK distributor signing certificate is needed.

## Configuration

The snapshot is prepared from the exact stable release in `vendor/openssl`, with its
revision, options, file hashes, and license recorded beside the sources. Preparation
uses OpenSSL's own Configure dependency graph and source generators in a temporary
directory; it never edits the submodule. This includes the default and legacy
providers and the modern key algorithms supported by SwiftSFTP. The package needs
libcrypto only; it previously distributed an unused OpenSSLSSL XCFramework.

All consumers, including Linux and Android, now use the pinned OpenSSL version.
System OpenSSL development packages and Android-specific OpenSSL build scripts are
no longer required. This makes algorithm support consistent across platforms.

The configuration uses portable C (`no-asm`) and selects the bignum word size at
compile time, including watchOS arm64_32. It supports the destination SDK and CPU
without maintaining prebuilt slices. The first build takes longer, and portable C
can be slower than architecture-specific assembly, particularly for encryption and
hashing. Previous transfer benchmarks were measured with the old binary builds and
are not performance results for this configuration.

Dynamic provider loading and automatic loading of a system OpenSSL configuration
are disabled. Providers are built in; cryptographic operations do not depend on
files or libraries installed outside the app. OpenSSL async contexts are disabled,
as required on iOS; SwiftSFTP's Swift concurrency APIs are unaffected. Apple builds
use CommonCrypto's random generator for OS entropy.

## Headers and symbol visibility

Public headers live under `SwiftSFTP_OpenSSL/`. Every canonical OpenSSL include in
the prepared C sources/headers is qualified to that tree, and the libssh2 adapter
is generated with the same qualification. This prevents an SDK with its own
`openssl/` headers from silently changing the declarations used for our build.

The prepared public headers assign SDK-private linker names with Clang's
`redefine_extname` pragma, preserving the existing C and Swift function names. Internal
symbols use hidden visibility; system library imports retain their normal visibility.
This also works when Swift Build partially links C targets before linking the final
product. OpenSSL is linked inside SwiftSFTP, and another SDK cannot replace its calls.
No unsafe compiler/linker flags
are needed in the package manifest. Keep the standalone crypto coexistence test:
the root test target alone does not verify a consumer's product linkage.

## Updating the pin

1. Move `vendor/openssl` to an exact **stable** `openssl-X.Y.Z` tag. Confirm
   `PRE_RELEASE_TAG` in `VERSION.dat` is empty.
2. Run `python3 Scripts/generate-openssl-sources.py`. Maintainers need Python 3.9+,
   Perl, and Make; consumers do not. The script generates source/header files only.
   Preparation also refreshes a SHA-256 stamp in `Package.swift`, invalidating
   manifest caches when the source/exclude lists change. Commit that stamp along
   with the snapshot.
3. When libssh2 changes, also run `python3 Scripts/generate-libssh2-backend.py`.
4. Verify the prepared files and build/test both the library and consumer:

   ```sh
   python3 Scripts/generate-openssl-sources.py --check
   python3 Scripts/generate-libssh2-backend.py --check
   bash Tests/Packaging/CryptoIsolation/check-header-isolation.sh
   swift build --scratch-path /private/tmp/SwiftSFTP-source-build
   swift test --scratch-path /private/tmp/SwiftSFTP-source-test
   swift test --package-path Tests/Packaging/CryptoIsolation --scratch-path /private/tmp/SwiftSFTP-source-consumer
   ```

5. Check iOS and the other supported Apple destinations as well as Linux/Android CI.
   Review changes to the generated configuration/dependency graph and privacy API
   usage. Commit the pin and prepared sources together; do not edit generated C or
   headers by hand. The privacy manifest declares file metadata use for app-container
   and user-selected files (`C617.1`, `3B52.1`), and elapsed-time/timer calculations
   (`35F9.1`). It declares no SDK tracking or developer-controlled data collection.

CI regenerates the snapshot with `--check`, ensuring it matches the pinned stable
release and contains no extra files. Package users compile the committed snapshot,
so generation is not part of their build and does not require a plugin approval.
