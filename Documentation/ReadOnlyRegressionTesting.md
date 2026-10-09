# Read-only path and OPEN regressions

These regressions cover [#6](https://github.com/RuiNelson/SwiftSFTP/issues/6) (significant filename whitespace) and [#7](https://github.com/RuiNelson/SwiftSFTP/issues/7) (the default mode sent for non-creation OPEN requests).

## Server-independent tests

`SFTPPathTests` checks absolute/relative whitespace, whitespace-only names, tabs/newlines, Unicode, existing component normalization, and explicit Windows conversion. The existing `WindowsSFTPPathTests` and `SFTPWindowsPathTests` cover the explicit conversion APIs.

```sh
swift test --filter 'SFTPPathTests|WindowsSFTPPathTests|SFTPWindowsPathTests'
```

## Optional independent server

Install the fixture dependency in a temporary virtual environment. This does not modify the system SSH service or any user files:

```sh
python3 -m venv /private/tmp/swiftsftp-regression-venv
/private/tmp/swiftsftp-regression-venv/bin/pip install 'asyncssh==2.24.0'
/private/tmp/swiftsftp-regression-venv/bin/python Scripts/read-only-regression-server.py
```

The script creates a temporary read-only chroot containing:

- `/one.bin`: exactly one zero byte.
- `/ spaced.bin `: bytes 0 through 98, with both spaces part of the filename.

It prints five shell-quoted `export SWIFTSFTP_REGRESSION_...` lines. Apply those values in the test process environment (or the Xcode Test action), then run:

```sh
swift test --filter SFTPReadOnlyRegressionTests
```

The suite is explicitly disabled when `SWIFTSFTP_REGRESSION_HOST` is absent. A disabled suite is not an integration pass. With the host set, missing credentials, unavailable server, and transfer errors fail the tests. No accept-any host-key policy is used.

For a physical iPhone, start the fixture with `--host <Mac LAN IP>`, pass the printed variables to an app-hosted test bundle, and allow Local Network access for its host app. A plain SwiftPM tool-hosted test bundle cannot run on physical iOS destinations. Stop the fixture with Ctrl-C after the test; its listener, connections, and generated files are cleaned up.

## Evidence and limits

Before the changes, an independent iPhone transport proof reproduced:

- `remoteFileNotFound` for the exact path `/ spaced.bin `.
- `SFTP status failure` for convenience `download()` with default OPEN permissions. An independent AsyncSSH client sending `0xffffffff` reproduced `mode out of range` during the server's ATTRS decoding on macOS 27 / Python 3.12.

The mode fix is at the shared Layer 0 OPEN boundary: when `.create` is absent, unused creation permissions are empty. Explicit permissions for creation remain unchanged. The read-only tests exercise both convenience `download()` and `openFile` without an explicit permissions argument; they do not substitute the earlier adapter workaround.

Stalled cancellation ([#8](https://github.com/RuiNelson/SwiftSFTP/issues/8)) requires separate pending-I/O handling and is not changed by these fixes. The original device measurement was 9.822705792 seconds to terminal result and cleanup after task cancellation; ≤2 seconds is an application acceptance criterion, not an existing documented library guarantee.

SwiftPM now compiles OpenSSL from the prepared sources for macOS and simulator destinations. A build failure before test execution is not a test pass. Physical-device app-hosted results and their exact counts are reported in the PR validation section separately from unsupported/unexecuted platforms.
