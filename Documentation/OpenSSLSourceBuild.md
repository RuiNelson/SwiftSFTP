# OpenSSL source builds

SwiftSFTP ships source code only. `OpenSSLCrypto` is a native SwiftPM C target built
from `vendor/SwiftSFTP-OpenSSL/Sources/OpenSSLCrypto/`, and libssh2 is compiled from its pinned submodule.
The OpenSSL snapshot and its preparation scripts live in the separate public
[SwiftSFTP-OpenSSL](https://github.com/RuiNelson/SwiftSFTP-OpenSSL) repository, included here as a submodule.
There are no binary targets, packaged XCFrameworks, or separate OpenSSL dylibs. The
dynamic SwiftSFTP product contains libcrypto and is signed by the consuming app's
normal build. No SDK distributor signing certificate is needed.

## Configuration

The snapshot is prepared from the exact stable release in the companion repository's
`vendor/openssl` submodule, with its
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

OpenSSL maintenance takes place in SwiftSFTP-OpenSSL. Its daily GitHub Actions workflow
opens one Issue when the official upstream publishes a newer stable release. It does
not update either repository automatically. A maintainer updates the OpenSSL pin,
regenerates the snapshot, runs that repository's CI and publishes the verified commit.
See the [companion repository's maintenance instructions](https://github.com/RuiNelson/SwiftSFTP-OpenSSL#updating-openssl).

Then update this repository:

1. Fetch the verified SwiftSFTP-OpenSSL commit and check it out in
   `vendor/SwiftSFTP-OpenSSL`. Keep the submodule pinned to a commit; consumer builds
   never follow the current upstream branch.
2. Initialize the nested OpenSSL checkout and refresh the parent manifest fingerprint:

   ```sh
   git -C vendor/SwiftSFTP-OpenSSL submodule update --init --checkout vendor/openssl
   python3 Scripts/update-openssl-manifest.py
   ```

   SwiftPM caches manifest evaluation without tracking arbitrary JSON reads. The
   SHA-256 stamp in `Package.swift` invalidates that cache when the submodule snapshot
   changes its source/exclude lists. Commit the parent stamp and submodule pin together.
3. When libssh2 changes, also run `python3 Scripts/generate-libssh2-backend.py`.
4. Verify the prepared files and build/test both the library and consumer:

   ```sh
   python3 vendor/SwiftSFTP-OpenSSL/Scripts/generate-openssl-sources.py --check
   python3 Scripts/update-openssl-manifest.py --check
   python3 Scripts/generate-libssh2-backend.py --check
   bash Tests/Packaging/CryptoIsolation/check-header-isolation.sh
   swift build --scratch-path /private/tmp/SwiftSFTP-source-build
   swift test --scratch-path /private/tmp/SwiftSFTP-source-test
   swift test --package-path Tests/Packaging/CryptoIsolation --scratch-path /private/tmp/SwiftSFTP-source-consumer
   ```

5. Check iOS and the other supported Apple destinations as well as Linux/Android CI.
   Review changes to configuration, dependency graphs and privacy API usage. The
   privacy manifest declares file metadata use for app-container and user-selected
   files (`C617.1`, `3B52.1`) and elapsed-time/timer calculations (`35F9.1`); it declares
   no SDK tracking or developer-controlled data collection.

Check out all submodules recursively in CI and manual clones. SwiftPM also initializes
nested submodules when fetching this package as a Git dependency. Package users compile
the committed prepared sources; generation is not part of their build and needs no
plugin approval, Perl or Make.
The companion repository's original OpenSSL submodule uses `update = none`, so consumers
fetch the prepared files only. Initialize that upstream checkout explicitly for source
verification as shown above; its unrelated upstream test submodules are not needed.
