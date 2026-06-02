# Test Server

Docker-based SSH/SFTP server for SwiftSFTP integration tests. Source lives in `TestServer/`; lifecycle scripts are in `Scripts/`.

## Quick start

From the repository root:

```bash
./Scripts/generate-test-keys-and-fixtures.sh
./Scripts/test-server-up.sh
```

Stop and remove the container (image is kept):

```bash
./Scripts/test-server-down.sh
```

Connect to `localhost` port **6922** (mapped to port 22 inside the container).

## Prerequisites

- `openssh` (`ssh-keygen`) and `openssl` on the host (for key generation)
- `python3` on the host (for binary fixtures)
- Docker (for the test server)

## Users and authentication

All users share the password **`pass123`**.

| Username   | Authentication | Algorithm |
| ---------- | -------------- | --------- |
| `bulbasaur`  | password only  | — |
| `charmander` | RSA public key | `rsa` |
| `squirtle`   | P-256 public key | `p256` |
| `caterpie`   | P-384 public key | `p384` |
| `weedle`     | P-521 public key | `p521` |
| `pidgey`     | Ed25519 public key | `ed25519` |

`bulbasaur` has no entry in `authorized_keys`; the other users authenticate with the OpenSSH public key installed at build time.

## Obtaining keys

### On the host (recommended for tests)

Run `./Scripts/generate-test-keys-and-fixtures.sh` from the repo root. Keys and fixtures are written under:

- `TestServer/KeyPairs/`
- `TestServer/Fixtures/`

These paths are local to your checkout. Regenerating keys replaces all files in those directories.

### Inside the running container

At build time, `KeyPairs/` and `Fixtures/` are copied to **`/home/bulbasaur/`** on the server. Connect as `bulbasaur` (password `pass123`) via SFTP or SSH to read them, for example:

```bash
sftp -P 6922 bulbasaur@localhost
# ls KeyPairs
# get KeyPairs/rsa-private-openssh-clear
```

Other users do not receive a copy of `KeyPairs/`; use `bulbasaur` or the host checkout when you need private key material for every algorithm.

## Key file naming

Each key file follows:

```text
{algorithm}-{public|private}-{format}-{clear|encrypted}
```

| Segment | Values |
| ------- | ------ |
| `algorithm` | `rsa`, `p256`, `p384`, `p521`, `ed25519` |
| `public` / `private` | key visibility |
| `format` | `openssh`, `pem`, `pkcs8` |
| `clear` / `encrypted` | unencrypted vs password-protected material |

Public keys are always `clear`. Only private PKCS#8 files use `encrypted`.

### Files per algorithm

For algorithm `{algo}` (e.g. `p521`):

| File | Description |
| ---- | ----------- |
| `{algo}-private-openssh-clear` | OpenSSH private key |
| `{algo}-public-openssh-clear` | OpenSSH public key (installed in `authorized_keys`) |
| `{algo}-private-pem-clear` | PEM private key. RSA/EC: traditional PEM. Ed25519: PKCS#8 PEM |
| `{algo}-private-pkcs8-clear` | PKCS#8 private key, unencrypted |
| `{algo}-private-pkcs8-encrypted` | PKCS#8 private key, AES-256-CBC encrypted |
| `{algo}-public-pem-clear` | PEM public key |

### Passwords for key files

| Purpose | Password |
| ------- | -------- |
| `*-private-pkcs8-encrypted` | `secret123` |
| Server user accounts | `pass123` |

All `clear` private keys have **no** passphrase.

### Example: RSA keys for `charmander`

```text
TestServer/KeyPairs/rsa-private-openssh-clear
TestServer/KeyPairs/rsa-public-openssh-clear      # → charmander authorized_keys
TestServer/KeyPairs/rsa-private-pem-clear
TestServer/KeyPairs/rsa-private-pkcs8-clear
TestServer/KeyPairs/rsa-private-pkcs8-encrypted
TestServer/KeyPairs/rsa-public-pem-clear
```

### Example: P-521 keys for `weedle`

```text
TestServer/KeyPairs/p521-private-openssh-clear
TestServer/KeyPairs/p521-public-openssh-clear     # → weedle authorized_keys
TestServer/KeyPairs/p521-private-pem-clear
TestServer/KeyPairs/p521-private-pkcs8-clear
TestServer/KeyPairs/p521-private-pkcs8-encrypted
TestServer/KeyPairs/p521-public-pem-clear
```

## Binary fixtures

Generated under `TestServer/Fixtures/`:

| File | Content | Size |
| ---- | ------- | ---- |
| `DEADBEAF.bin` | bytes `0xDE 0xAD 0xBE 0xAF` repeated 1024² times | 4 MiB |
| `SMALL.bin` | byte `0xAA` repeated 1024 times | 1 KiB |
| `TINY.bin` | single byte `0x00` | 1 byte |
| `NO_DATA.bin` | empty file | 0 bytes |

Like `KeyPairs/`, fixtures are available on the host after generation and on the server at `/home/bulbasaur/Fixtures/`.

## Server layout (selected homes)

### `charmander` — directories and symlinks

```text
~/documents/report.txt
~/archives/2024/log.txt
~/current              → documents
~/latest-report        → documents/report.txt
```

### `squirtle` — permission and ownership cases

| File | Mode | Owner |
| ---- | ---- | ----- |
| `readable.txt` | 644 | squirtle |
| `writable.txt` | 644 | squirtle |
| `readonly.txt` | 444 | squirtle |
| `noaccess.txt` | 000 | squirtle |
| `executable.sh` | 755 | squirtle |
| `root-owned.txt` | 644 | root:root |

## Docker details

| Setting | Value |
| ------- | ----- |
| Image name | `swiftsftp-testserver` |
| Container name | `swiftsftp-testserver` |
| Host port | `6922` |
| Container port | `22` |
| Base image | `debian:testing` |

Host keys are generated automatically when the container starts (`ssh-keygen -A` in the entrypoint). SSH displays a MOTD on interactive shell login (`/etc/motd`); pure SFTP sessions typically do not show it.

## Related scripts and files

| Path | Role |
| ---- | ---- |
| `Scripts/generate-test-keys-and-fixtures.sh` | Generate `KeyPairs/` and `Fixtures/` |
| `Scripts/test-server-up.sh` | Build image and start container |
| `Scripts/test-server-down.sh` | Stop and remove container |
| `TestServer/Dockerfile` | Server image |
| `TestServer/setup-test-server.sh` | Users, keys, home layouts (run at image build) |
| `TestServer/motd` | MOTD text |
