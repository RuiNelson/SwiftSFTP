# Cryptographic Utilities

SwiftSFTP exposes OpenSSL-backed helpers under `Sources/SwiftSFTP/CryptographicUtils/` for offline validation of user authentication keys and OpenSSH `known_hosts` host keys, plus asymmetric key generation, import, and export in OpenSSH, PEM, PKCS#8, and DER formats.

All validation APIs return simple `Bool` values. They check that a key is well formed and cryptographically valid — they do not verify that a key is authorized on any particular server.

---

## User Authentication Key Validation (`KeyValidation`)

`String` conforms to `KeyValidation`, allowing you to check PEM, PKCS#8, OpenSSH private key, and OpenSSH one-line public key strings before using them for user authentication.

### Supported formats

| Format | Private key | Public key |
|--------|-------------|------------|
| PEM / PKCS#8 (`BEGIN PRIVATE KEY`, `BEGIN EC PRIVATE KEY`, etc.) | ✓ | ✓ (`BEGIN PUBLIC KEY`) |
| Encrypted PKCS#8 / legacy encrypted PEM | ✓ (with passphrase) | — |
| OpenSSH private key (`BEGIN OPENSSH PRIVATE KEY`) | ✓ (clear, or with passphrase) | — |
| OpenSSH one-line public key (`ssh-ed25519 AAAA… [comment]`, etc.) | — | ✓ |

### Supported algorithms

Every `AsymmetricKeyType`: Ed25519, Ed448, ECDSA P-256/P-384/P-521, RSA, ML-DSA-44/65/87 and all SLH-DSA parameter sets (see [Asymmetric Keys](#asymmetric-keys-asymmetriccryptography)). Keys of other OpenSSL algorithms (DSA, X25519, Brainpool curves, …) are rejected.

### What "valid" means

The `isValid_` checks ask whether the string is a valid key of any supported algorithm:

- it parses in one of the formats above;
- public keys are valid for their algorithm — for example, an EC point lies on its curve and is not the point at infinity;
- private keys are consistent — their private and public halves belong together, so a tampered key whose embedded public key belongs to another key is rejected.

No acceptance policy applies: a 768-bit RSA key is a valid key.

### Valid vs. valid for SSH

A valid key is not necessarily one SSH will use. The `isValidForSSH_` checks add OpenSSH's own rules:

- the algorithm is one OpenSSH defines — Ed25519, ECDSA P-256/P-384/P-521, or RSA (not Ed448, ML-DSA, or SLH-DSA);
- RSA moduli are 1024 to 16384 bits.

```swift
pem.isValid_PrivateKey(passphrase: "passphrase")         // any valid key
pem.isValidForSSH_PrivateKey(passphrase: "passphrase")   // a key OpenSSH accepts
line.isValidForSSH_PublicKey
```

`PrivateKeyString` and `PrivateKeyFile` follow the same split: `.valid` accepts any valid key, `.isValidForSSH` only keys OpenSSH accepts (it is `true` exactly when `.algorithm` is non-`nil`). `SSHUserKeyAlgorithm.detect(from:passphrase:)` returns `nil` for keys SSH will not use.

### Passphrases

Functions that take `passphrase: String? = nil` accept unencrypted keys whatever the passphrase. Encrypted keys must decrypt with it; `nil` or an empty string rejects them. The passphrase is used as its exact UTF-8 bytes in every format.

The `password:` variants (`isValid_PrivateKey(password:)`, `isValid_RSA_PrivateKey(password:)`, …) are deprecated in favour of `passphrase:`.

### Key type

`privateKeyType`, `privateKeyType(passphrase:)` and `publicKeyType` return the key's `AsymmetricKeyType`, or `nil` when the string is not a valid key:

```swift
if pem.privateKeyType(passphrase: "passphrase") == .ed448 {
    // decryptable Ed448 private key
}
```

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
    // well-formed unencrypted private key
}

if pem.isValidForSSH_PrivateKey(passphrase: "passphrase") {
    // decryptable private key SFTPClient can authenticate with
}
```

### Algorithm-specific checks

Private keys:

```swift
pem.isValid_RSA_PrivateKey
pem.isValid_P256_PrivateKey
pem.isValid_P384_PrivateKey
pem.isValid_P521_PrivateKey
pem.isValid_Curve25519_PrivateKey   // Ed25519
```

Public keys:

```swift
pem.isValid_RSA_PublicKey
pem.isValid_P256_PublicKey
pem.isValid_P384_PublicKey
pem.isValid_P521_PublicKey
pem.isValid_Curve25519_PublicKey
```

Encrypted private keys use the `passphrase:` variants, for example `isValid_RSA_PrivateKey(passphrase:)`. For other key types, compare `privateKeyType` / `publicKeyType` with the `AsymmetricKeyType` you expect.

OpenSSH one-line public keys (as used in `authorized_keys`, with or without a trailing comment, but without leading options) are accepted by the `_PublicKey` checks:

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
    // well formed, cryptographically valid, and accepted by OpenSSH
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

Validation decodes the base64 wire blob, which must name the line's algorithm and carry exactly its components, then checks the key with OpenSSL (EC points on their curve and not at infinity, DSA public values in their subgroup) and applies OpenSSH's rules (RSA moduli of 1024 to 16384 bits). `@cert-authority` and `@revoked` marker lines are not accepted.

### Known hosts host fields

`TCPLocation.isValidKnownHostsHostField(_:)` validates the host column used in `known_hosts` lines. Accepted forms include:

- IPv4 addresses (`127.0.0.1`, `10.0.0.1:2222`)
- Bracketed hostnames and IPv6 (`[example.com]`, `[2001:db8::1]:443`)
- Plain hostnames (`example.com`, `localhost`)
- Hashed hosts (`|1|<salt>|<hash>`)
- Comma-separated lists (`127.0.0.1,example.com`)

`TCPLocation.knownHostsHost` produces host strings in this format when constructing entries from a `TCPLocation`.

---

## Asymmetric Keys (`AsymmetricCryptography`)

`AsymmetricCryptography` generates, imports, and exports signature keys for every algorithm below, in every format OpenSSL and OpenSSH define for them.

### Algorithms

| Namespace | Key type | OpenSSH name |
|-----------|----------|--------------|
| `AsymmetricCryptography.EdDSA.Ed25519` | `.ed25519` | `ssh-ed25519` |
| `AsymmetricCryptography.EdDSA.Ed448` | `.ed448` | — |
| `AsymmetricCryptography.ECDSA.P256` / `P384` / `P521` | `.ecdsaP256` / `.ecdsaP384` / `.ecdsaP521` | `ecdsa-sha2-nistp256` / `384` / `521` |
| `AsymmetricCryptography.RSA` | `.rsa` | `ssh-rsa` |
| `AsymmetricCryptography.MLDSA.MLDSA44` / `MLDSA65` / `MLDSA87` | `.mlDSA44` / `.mlDSA65` / `.mlDSA87` | — |
| `AsymmetricCryptography.SLHDSA.SHA2_128s` … `SHAKE_256f` (12 parameter sets) | `.slhDSA_SHA2_128s` … | — |

ML-DSA and SLH-DSA need OpenSSL 3.5 or later. The bundled Apple XCFrameworks include it; on Linux, check `AsymmetricKeyType.isAvailable` against the system OpenSSL.

RSA keys default to 3072 bits (`RSA.generateKeyPair(bits:)` accepts 2048–16384). A single RSA key serves both PKCS#1 v1.5 and PSS signatures.

### Formats

| Format | Private key | Public key | Key types |
|--------|-------------|------------|-----------|
| `.openSSH` | `BEGIN OPENSSH PRIVATE KEY`; with a passphrase, aes256-ctr + bcrypt, like `ssh-keygen` | `ssh-ed25519 AAAA…` | Ed25519, ECDSA, RSA |
| `.pkcs8` | `BEGIN PRIVATE KEY`; with a passphrase, `BEGIN ENCRYPTED PRIVATE KEY` (PBES2, AES-256-CBC) | — | all |
| `.pem` | `BEGIN RSA PRIVATE KEY` / `BEGIN EC PRIVATE KEY` (legacy PEM encryption) | `BEGIN PUBLIC KEY` (SubjectPublicKeyInfo) | private: RSA, ECDSA; public: all |
| DER | `derRepresentation` (PKCS#8) | `derRepresentation` (SubjectPublicKeyInfo) | all |

Parsing accepts all of the above, ignoring text around a key's `BEGIN` and `END` lines. It also reads OpenSSH keys encrypted with aes128/192/256-ctr, aes128/192/256-cbc, and aes128/256-gcm@openssh.com. `chacha20-poly1305@openssh.com` is not supported. Keys whose bcrypt KDF asks for more than 1024 rounds are rejected with `unsupportedEncryption`: each round costs about 9 ms on Apple silicon, so the limit bounds decryption at about 10 seconds, where a crafted file could otherwise stall it indefinitely (`ssh-keygen` uses 16 rounds by default). Such keys also fail `isValid_PrivateKey(passphrase:)` and `SSHUserKeyAlgorithm.detect`, but `SFTPClient` still tries them last during authentication, when libssh2 decrypts them itself. OpenSSH does not define Ed448, ML-DSA, or SLH-DSA keys, so those throw `unsupportedPrivateKeyFormat` / `unsupportedPublicKeyFormat` for `.openSSH`.

### Generating keys

```swift
import SwiftSFTP

let pair = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair()

let privateKey = try pair.privateKey.encode(format: .openSSH, passphrase: "passphrase")
let publicKey = try pair.publicKey.encode(format: .openSSH) // "ssh-ed25519 AAAA…"
```

### Importing and converting keys

```swift
let key = try PrivateKey(string: pem, passphrase: "passphrase") // OpenSSH, PKCS#8 or algorithm-specific PEM
key.type                                                        // e.g. .ecdsaP256
let authorizedKey = try key.publicKey.encode(format: .openSSH)
let pkcs8 = try key.encode(format: .pkcs8)

let publicKey = try PublicKey(string: "ssh-ed25519 AAAA… user@host") // or a PEM PUBLIC KEY
```

Imported keys are checked as described in [What "valid" means](#what-valid-means): public keys must be valid for their algorithm, and private keys consistent, so `key.publicKey` is always the key that verifies `key`'s signatures. `PrivateKey` and `PublicKey` apply no SSH policy; use the `isValidForSSH_` checks for that.

`AsymmetricAlgorithm.derivePublicKey(from:)` returns the pair for a private key and checks that the key is of that algorithm. `PrivateKey`, `PublicKey`, and `AsymmetricKeyPair` are `Codable` as their DER form; decoding validates the key.

Errors are thrown as `AsymmetricCryptographyError`, for example `.passphraseRequired`, `.incorrectPassphrase`, `.invalidKeyData`, or `.unsupportedAlgorithm("X25519")`.

### Deprecated Ed25519 API

`SwiftSFTP_Curve25519` and `OpenSSHKeyPair` are deprecated and now forward to `AsymmetricCryptography`:

| Deprecated | Replacement |
|------------|-------------|
| `SwiftSFTP_Curve25519.generateKeyPairInOpenSSHFormat()` | `AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair()` + `encode(format: .openSSH)` |
| `SwiftSFTP_Curve25519.generatePublicKeyFromPrivateKey(openSSHFormat:)` | `PrivateKey(string:).publicKey.encode(format: .openSSH)` |

---

## What These APIs Do Not Check

- Whether a private key matches a server's `authorized_keys` entry
- Whether a host key belongs to the host you intend to connect to
- Certificate chains, expiry, or revocation
- Key strength policy beyond basic parseability

Use `SFTPClient` host key acceptance policies and server-side authorization for connection-time trust decisions.
