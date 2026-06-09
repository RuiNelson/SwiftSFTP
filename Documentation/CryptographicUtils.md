# Cryptographic Utilities

SwiftSFTP exposes OpenSSL-backed helpers under `Sources/SwiftSFTP/CryptographicUtils/` for offline validation of user authentication keys and OpenSSH `known_hosts` host keys, plus Ed25519 key generation in OpenSSH formats.

All validation APIs return simple `Bool` values. They check format and cryptographic parseability only — they do not verify that a key is authorized on any particular server.

---

## User Authentication Key Validation (`KeyValidation`)

`String` conforms to `KeyValidation`, allowing you to check PEM, PKCS#8, OpenSSH private key, and OpenSSH one-line public key strings before using them for user authentication.

### Supported formats

| Format | Private key | Public key |
|--------|-------------|------------|
| PEM / PKCS#8 (`BEGIN PRIVATE KEY`, `BEGIN EC PRIVATE KEY`, etc.) | ✓ | ✓ (`BEGIN PUBLIC KEY`) |
| Encrypted PEM (`BEGIN ENCRYPTED PRIVATE KEY`) | ✓ (with password) | — |
| OpenSSH private key (`BEGIN OPENSSH PRIVATE KEY`) | ✓ (unencrypted) | — |
| OpenSSH one-line public key (`ssh-ed25519 AAAA…`, etc.) | — | ✓ |

### Supported algorithms

- RSA
- ECDSA P-256, P-384, P-521
- Ed25519 (Curve25519)

### Generic checks

```swift
import SwiftSFTP

let pem = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIGU49N3pXnY7QLxXGEf9vFayuBzcGp4knY1aFQbVgfeCoAoGCCqGSM49
    AwEHoUQDQgAEMSzxTnxAxZ8MxL9AXDScmv1pcWOXh8N3QYo4O+dvBVeFsaumKxit
    t3f3yxw97qIw5d+uUvDo1+1S7tcYRkWfIA==
    -----END EC PRIVATE KEY-----
    """

if pem.isValid_PrivateKey {
    // safe to pass to SFTPClient authentication
}

if pem.isValid_PrivateKey(password: "passphrase") {
    // decryptable encrypted private key
}
```

### Algorithm-specific checks

Private keys:

```swift
pem.isValid_RSA_PrivateKey
pem.isValid_P256_PrivateKey
pem.isValid_P384_PrivateKey
pem.isValid_P521_PrivateKey
pem.isValid_Curve25519_PrivateKey   // Ed25519 / OpenSSH private key format
```

Public keys:

```swift
pem.isValid_RSA_PublicKey
pem.isValid_P256_PublicKey
pem.isValid_P384_PublicKey
pem.isValid_P521_PublicKey
pem.isValid_Curve25519_PublicKey
```

Encrypted private keys also expose password variants, for example `isValid_RSA_PrivateKey(password:)`.

OpenSSH one-line public keys (as used in `authorized_keys`) are accepted by the `_PublicKey` checks:

```swift
let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIMQcpIxd7XrCEeqjqair0YJgbOJzhna+0ZqQKFp/w1s"
#expect(publicKey.isValid_Curve25519_PublicKey)
#expect(publicKey.isValid_PublicKey)
```

---

## Host Key Validation (`known_hosts`)

`String` exposes properties to validate OpenSSH host key material before storing or comparing `known_hosts` entries.

### Shorthand host key

Validates a two-field line: `algorithm base64-key`.

```swift
let shorthand = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIMQcpIxd7XrCEeqjqair0YJgbOJzhna+0ZqQKFp/w1s"

if shorthand.isValid_ShortHandHostKey {
    // structurally valid and cryptographically parseable
}
```

### Full `known_hosts` line

Validates a three-field line: `host algorithm base64-key`. The host field is checked with `TCPLocation.isValidKnownHostsHostField(_:)`.

```swift
let line = "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIMQcpIxd7XrCEeqjqair0YJgbOJzhna+0ZqQKFp/w1s"

if line.isValid_HostKey {
    // valid known_hosts entry
}
```

### Supported host key algorithms

- `ssh-rsa`
- `ecdsa-sha2-nistp256`
- `ecdsa-sha2-nistp384`
- `ecdsa-sha2-nistp521`
- `ssh-ed25519`
- `ssh-dss`

Validation decodes the base64 wire blob and verifies the public key material with OpenSSL.

### Known hosts host fields

`TCPLocation.isValidKnownHostsHostField(_:)` validates the host column used in `known_hosts` lines. Accepted forms include:

- IPv4 addresses (`127.0.0.1`, `10.0.0.1:2222`)
- Bracketed hostnames and IPv6 (`[example.com]`, `[2001:db8::1]:443`)
- Plain hostnames (`example.com`, `localhost`)
- Hashed hosts (`|1|<salt>|<hash>`)
- Comma-separated lists (`127.0.0.1,example.com`)

`TCPLocation.knownHostsHost` produces host strings in this format when constructing entries from a `TCPLocation`.

---

## Ed25519 Key Generation

`SwiftSFTP_Curve25519` generates unencrypted Ed25519 key pairs in OpenSSH formats.

```swift
import SwiftSFTP

if let pair = SwiftSFTP_Curve25519.generateKeyPairInOpenSSHFormat() {
    // pair.privateKey — PEM ("BEGIN OPENSSH PRIVATE KEY")
    // pair.publicKey  — "ssh-ed25519 <base64>"

    #expect(pair.privateKey.isValid_Curve25519_PrivateKey)
    #expect(pair.publicKey.isValid_Curve25519_PublicKey)
}
```

Extract the public key from an existing unencrypted OpenSSH private key:

```swift
if let publicKey = SwiftSFTP_Curve25519.generatePublicKeyFromPrivateKey(
    openSSHFormat: pair.privateKey
) {
    #expect(publicKey == pair.publicKey)
}
```

`OpenSSHKeyPair` holds the generated `privateKey` and `publicKey` strings. Passphrase encryption is not supported by the generator.

---

## What These APIs Do Not Check

- Whether a private key matches a server's `authorized_keys` entry
- Whether a host key belongs to the host you intend to connect to
- Certificate chains, expiry, or revocation
- Key strength policy beyond basic parseability

Use `SFTPClient` host key acceptance policies and server-side authorization for connection-time trust decisions.
