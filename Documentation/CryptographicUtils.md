# Cryptographic Utilities

SwiftSFTP includes OpenSSL-backed key utilities under `Sources/SwiftSFTP/CryptographicUtils/`. They cover four tasks:

1. [Generating key pairs](#generating-key-pairs) — create new keys and save them in OpenSSH, PKCS#8, PEM, or DER form.
2. [Deriving public keys from private keys](#deriving-public-keys-from-private-keys) — the equivalent of
   `ssh-keygen -y`.
3. [Validating existing key pairs](#validating-existing-key-pairs) — check user authentication keys, and whether a
   private and a public key belong together.
4. [Validating host key entries](#validating-host-key-entries) — check `known_hosts` lines and shorthand host keys.

Everything here runs offline: no API contacts a server. A [reference](#reference) of algorithms, formats, and errors
follows the four tasks.

The main types are:

| Type | Role |
|------|------|
| `AsymmetricCryptography` | One namespace per algorithm (`EdDSA.Ed25519`, `ECDSA.P256`, `RSA`, …), each able to generate keys. |
| `PrivateKey` | A private key of any supported algorithm, together with its `publicKey`. |
| `PublicKey` | A public key of any supported algorithm. |
| `AsymmetricKeyPair` | A `privateKey` and its `publicKey`, as returned by key generation. |
| `AsymmetricKeyType` | The algorithm and parameters of a key (`.ed25519`, `.ecdsaP256`, `.rsa`, …). |
| `KeyValidation` (on `String`) | `Bool` checks for private and public key text. |
| `String.isValid_HostKey` / `isValid_ShortHandHostKey` | `Bool` checks for host key entries. |

---

## Generating Key Pairs

Pick an algorithm namespace and call `generateKeyPair()`. The result is an `AsymmetricKeyPair`; encode each half in
the format you need:

```swift
import SwiftSFTP

let pair = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair()

let privateKeyFile = try pair.privateKey.encode(format: .openSSH, passphrase: "passphrase")
// "-----BEGIN OPENSSH PRIVATE KEY-----…"
let authorizedKey = try pair.publicKey.encode(format: .openSSH)
// "ssh-ed25519 AAAA…", ready for authorized_keys
```

### Choosing an algorithm

For SSH user authentication, generate one of the keys OpenSSH defines:

| Namespace | Notes |
|-----------|-------|
| `AsymmetricCryptography.EdDSA.Ed25519` | Recommended default: small, fast keys, as `ssh-keygen` generates by default. |
| `AsymmetricCryptography.ECDSA.P256` / `P384` / `P521` | For servers or policies that require NIST curves. |
| `AsymmetricCryptography.RSA` | For servers that accept only RSA. 3072 bits by default. |

RSA takes an optional modulus size between `RSA.minimumBits` (2048) and `RSA.maximumBits` (16384); other sizes throw
`invalidKeySize`:

```swift
let rsaPair = try AsymmetricCryptography.RSA.generateKeyPair(bits: 4096)
```

Ed448, ML-DSA, and SLH-DSA keys can be generated too, but OpenSSH does not define them, so they cannot be used to
log in to an SSH server, and they have no `.openSSH` encoding. See [Algorithms](#algorithms) for the full list.

Every namespace conforms to `AsymmetricAlgorithm`, so code can take the algorithm as a parameter:

```swift
func makeKey(_ algorithm: any AsymmetricAlgorithm.Type) throws -> AsymmetricKeyPair {
    try algorithm.generateKeyPair()
}
```

### Encoding the private key

`PrivateKey.encode(format:passphrase:)` returns text in one of three formats. A non-empty passphrase encrypts the
key; `nil` or an empty string leaves it unencrypted.

| Format | Output | Encryption with a passphrase | Key types |
|--------|--------|------------------------------|-----------|
| `.openSSH` | `BEGIN OPENSSH PRIVATE KEY` | aes256-ctr with bcrypt, as `ssh-keygen` does | Ed25519, ECDSA, RSA |
| `.pkcs8` | `BEGIN PRIVATE KEY` | `BEGIN ENCRYPTED PRIVATE KEY` (PBES2, AES-256-CBC) | all |
| `.pem` | `BEGIN RSA PRIVATE KEY` / `BEGIN EC PRIVATE KEY` | legacy PEM encryption (AES-256-CBC) | RSA, ECDSA |

Use `.openSSH` for keys that SSH clients will read, and `.pkcs8` for other tools; `.pem` exists for software that
needs the legacy algorithm-specific form. `privateKey.derRepresentation` holds the key as unencrypted DER PKCS#8.

Asking for a format the key type does not have throws `unsupportedPrivateKeyFormat`, for example `.openSSH` for an
Ed448 key.

### Encoding the public key

`PublicKey.encode(format:)` returns:

- `.openSSH` — a one-line key such as `ssh-ed25519 AAAA…`, for `authorized_keys`. Only Ed25519, ECDSA, and RSA keys
  have one; other key types throw `unsupportedPublicKeyFormat`.
- `.pem` — `BEGIN PUBLIC KEY` (SubjectPublicKeyInfo), for every key type.

`publicKey.derRepresentation` holds the DER-encoded SubjectPublicKeyInfo.

The OpenSSH line has no comment. Append one, such as `user@host`, if you want it to appear in `authorized_keys`.

### Saving a key file

OpenSSH refuses private key files that other users can read, so write them with `0600` permissions:

```swift
let pair = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair()
let keyFile = try pair.privateKey.encode(format: .openSSH, passphrase: "passphrase")
let authorizedKey = try pair.publicKey.encode(format: .openSSH) + " user@host"

FileManager.default.createFile(
    atPath: "/path/to/id_ed25519",
    contents: Data(keyFile.utf8),
    attributes: [.posixPermissions: 0o600]
)
try (authorizedKey + "\n").write(toFile: "/path/to/id_ed25519.pub", atomically: true, encoding: .utf8)
```

### Storing keys with `Codable`

`PrivateKey`, `PublicKey`, and `AsymmetricKeyPair` are `Codable`. They encode as their DER form; decoding checks the
key again, and `AsymmetricKeyPair` rejects a pair whose halves do not match. A `PrivateKey` encodes unencrypted, so
protect the encoded data as you would the key itself.

---

## Deriving Public Keys from Private Keys

Every `PrivateKey` carries its public key. Deriving the public key of an existing private key — what
`ssh-keygen -y` does — is a parse followed by a property access:

```swift
import SwiftSFTP

let keyFile = try String(contentsOfFile: "/Users/me/.ssh/id_ed25519", encoding: .utf8)
let privateKey = try PrivateKey(string: keyFile, passphrase: "passphrase") // or nil for an unencrypted key

let publicKey = privateKey.publicKey
let authorizedKey = try publicKey.encode(format: .openSSH) // "ssh-ed25519 AAAA…"
let pem = try publicKey.encode(format: .pem)               // "-----BEGIN PUBLIC KEY-----…"
let der = publicKey.derRepresentation                      // DER-encoded SubjectPublicKeyInfo
```

`privateKey.type` tells you which algorithm the key uses.

### What `PrivateKey(string:passphrase:)` reads

- OpenSSH private keys (`BEGIN OPENSSH PRIVATE KEY`), unencrypted or encrypted with aes128/192/256-ctr,
  aes128/192/256-cbc, or aes128/256-gcm@openssh.com. `chacha20-poly1305@openssh.com` is not supported.
- PKCS#8 (`BEGIN PRIVATE KEY`, or `BEGIN ENCRYPTED PRIVATE KEY`).
- Algorithm-specific PEM (`BEGIN RSA PRIVATE KEY`, `BEGIN EC PRIVATE KEY`), unencrypted or with legacy PEM encryption.

Text before the `BEGIN` line and after the `END` line, such as a file name or a comment, is ignored. Binary keys go
through `PrivateKey(derRepresentation:)`, which takes unencrypted PKCS#8, PKCS#1 (RSA), or SEC 1 (EC) DER.

The passphrase is used as its exact UTF-8 bytes. An encrypted key throws `passphraseRequired` when the passphrase is
`nil` or empty, and `incorrectPassphrase` when it does not decrypt the key. Unencrypted keys ignore the passphrase.

OpenSSH keys whose bcrypt KDF asks for more than 1024 rounds throw `unsupportedEncryption`. Each round costs about
9 ms on Apple silicon, so the limit keeps decryption under about 10 seconds, where a crafted file could otherwise stall
it indefinitely. `ssh-keygen` uses 16 rounds by default.

### Requiring a particular algorithm

When the key must be of one algorithm, derive the pair through that algorithm's namespace.
`derivePublicKey(from:)` returns the `AsymmetricKeyPair` and throws `keyTypeMismatch` for a key of any other type:

```swift
let pair = try AsymmetricCryptography.EdDSA.Ed25519.derivePublicKey(from: privateKey)
let authorizedKey = try pair.publicKey.encode(format: .openSSH)
```

### The derived key is always the right one

Parsing checks that the private key's halves belong together. A tampered key file whose embedded public key belongs
to another key is rejected with `invalidKeyData`, so `privateKey.publicKey` is always the key that verifies
`privateKey`'s signatures.

---

## Validating Existing Key Pairs

Before using keys you did not create — imported by a user, read from disk, pasted into a form — check them. SwiftSFTP
offers two styles:

- **`Bool` checks** on `String`, through `KeyValidation`, for a quick yes or no.
- **Throwing initializers** (`PrivateKey(string:passphrase:)`, `PublicKey(string:)`), when you need the reason a key
  was rejected or the parsed key itself.

Both apply the same checks. None of them tells you whether a server will authorize a key; see
[What these APIs do not check](#what-these-apis-do-not-check).

### Valid keys and keys SSH accepts

There are two levels of validity:

| Level | Checks | Accepts |
|-------|--------|---------|
| Valid | `isValid_PrivateKey`, `isValid_PublicKey`, `PrivateKey`, `PublicKey` | A well-formed, valid key of any [supported algorithm](#algorithms). No policy applies: a 768-bit RSA key is a valid key. |
| Accepted by SSH | `isValidForSSH_PrivateKey(passphrase:)`, `isValidForSSH_PublicKey` | A valid key that OpenSSH will also use: Ed25519, ECDSA P-256/P-384/P-521, or RSA with a 1024- to 16384-bit modulus and a public exponent above 1. Ed448, ML-DSA, and SLH-DSA keys are rejected. |

A key is valid when:

- it parses in one of the [supported formats](#formats);
- its public key is valid for its algorithm — for example, an EC point lies on its curve and is not the point at
  infinity;
- for a private key, its private and public halves belong together.

Keys of algorithms SwiftSFTP does not support (DSA, X25519, Brainpool curves, …) are never valid.

Use the SSH level for keys that `SFTPClient` will authenticate with, and the plain level when the key is meant for
something else.

### Private keys

```swift
import SwiftSFTP

let keyText = try String(contentsOfFile: "/Users/me/.ssh/id_ecdsa", encoding: .utf8)

keyText.isValid_PrivateKey                                   // valid and unencrypted
keyText.isValid_PrivateKey(passphrase: "passphrase")         // valid, encrypted or not
keyText.isValidForSSH_PrivateKey(passphrase: "passphrase")   // valid, and SFTPClient can log in with it
keyText.privateKeyType(passphrase: "passphrase")             // e.g. .ecdsaP256, or nil
```

Passphrases follow one rule everywhere: unencrypted keys pass whatever the passphrase, and encrypted keys must
decrypt with it. A `nil` or empty passphrase therefore rejects every encrypted key. The properties without a
`passphrase:` parameter (`isValid_PrivateKey`, `privateKeyType`) accept only unencrypted keys.

OpenSSH keys encrypted with more than 1024 bcrypt rounds fail these checks, since SwiftSFTP will not decrypt them.
`SFTPClient` still tries such keys last during authentication, when libssh2 decrypts them itself.

### Public keys

Public keys can be PEM (`BEGIN PUBLIC KEY`) or OpenSSH one-line keys, as found in `authorized_keys`, with or without
a trailing comment but without leading options:

```swift
let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIMQcpIxd7XrCEeqjqair0YJgbOJzhna+0ZqQKFp/w1s user@host"

line.isValid_PublicKey      // true
line.isValidForSSH_PublicKey // true
line.publicKeyType          // .ed25519
```

### Checking for a particular algorithm

Compare `privateKeyType` or `publicKeyType` with the `AsymmetricKeyType` you expect:

```swift
if keyText.privateKeyType(passphrase: "passphrase") == .ed25519 {
    // a decryptable Ed25519 private key
}
```

Shortcuts exist for the SSH algorithms. Each private key check also has a `passphrase:` variant, such as
`isValid_RSA_PrivateKey(passphrase:)`:

| Algorithm | Private key | Public key |
|-----------|-------------|------------|
| Ed25519 | `isValid_Curve25519_PrivateKey` | `isValid_Curve25519_PublicKey` |
| ECDSA P-256 | `isValid_P256_PrivateKey` | `isValid_P256_PublicKey` |
| ECDSA P-384 | `isValid_P384_PrivateKey` | `isValid_P384_PublicKey` |
| ECDSA P-521 | `isValid_P521_PrivateKey` | `isValid_P521_PublicKey` |
| RSA | `isValid_RSA_PrivateKey` | `isValid_RSA_PublicKey` |

These check validity only: `isValid_RSA_PublicKey` is `true` for a 768-bit RSA key. Combine them with
`isValidForSSH_…` when the key is meant for SSH.

### Checking that a private and a public key belong together

To confirm that a public key — an `authorized_keys` line, a `.pub` file — matches a private key, parse both and
compare the private key's public half with it:

```swift
let privateKey = try PrivateKey(string: keyText, passphrase: "passphrase")
let publicKey = try PublicKey(string: line)

if privateKey.publicKey == publicKey {
    // the public key belongs to this private key
}
```

`PublicKey` values compare by their DER form, so the comparison ignores the text format (OpenSSH or PEM) and any
comment.

### Finding out why a key is rejected

The throwing initializers report the reason as an `AsymmetricCryptographyError`:

```swift
do {
    let privateKey = try PrivateKey(string: keyText, passphrase: passphrase)
    // use privateKey
} catch AsymmetricCryptographyError.passphraseRequired {
    // ask the user for the passphrase
} catch AsymmetricCryptographyError.incorrectPassphrase {
    // ask again
} catch AsymmetricCryptographyError.unsupportedAlgorithm(let name) {
    // a key of an algorithm SwiftSFTP does not support, such as "X25519"
} catch {
    // invalidKeyData, unsupportedEncryption, …
}
```

`PrivateKey` and `PublicKey` apply no SSH policy. Check `isValidForSSH_…` as well when the key is meant for SSH.

### Keys configured for `SFTPClient`

The key types `SFTPClient` authenticates with apply the same checks:

- `PrivateKeyString` and `PrivateKeyFile` have `valid` (any valid key) and `isValidForSSH` (a key OpenSSH accepts).
  `PrivateKeyFile` reads the file each time.
- Their `algorithm` property returns the key's `SSHUserKeyAlgorithm` (`.ed25519`, `.ecdsaP256`, …, `.rsa`), or `nil`
  for a key SSH will not use. `isValidForSSH` is `true` exactly when `algorithm` is non-`nil`.
- `SSHUserKeyAlgorithm.detect(from:passphrase:)` does the same for key text.

---

## Validating Host Key Entries

A host key entry pairs a server's public host key with the hosts it belongs to. Validate entries before storing them
or passing them to `HostKeyAcceptance`, so that a malformed entry is caught early instead of failing at login.

There are two shapes of entry, each with its own check on `String`:

| Shape | Example | Check | Used by |
|-------|---------|-------|---------|
| Full `known_hosts` line | `example.com ssh-ed25519 AAAA… [comment]` | `isValid_HostKey` | `known_hosts` files, `.loadFromFile`, `.loadFromFileString` |
| Shorthand host key | `ssh-ed25519 AAAA…` | `isValid_ShortHandHostKey` | `.shortHandAcceptedKeys` |

```swift
import SwiftSFTP

let line = "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIMQcpIxd7XrCEeqjqair0YJgbOJzhna+0ZqQKFp/w1s"
line.isValid_HostKey // true

let shorthand = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIMQcpIxd7XrCEeqjqair0YJgbOJzhna+0ZqQKFp/w1s"
shorthand.isValid_ShortHandHostKey // true
```

A full line may end with a comment. A shorthand key must be exactly two fields, so remove any comment before
checking it.

### Host key algorithms

- `ssh-ed25519`
- `ecdsa-sha2-nistp256`, `ecdsa-sha2-nistp384`, `ecdsa-sha2-nistp521`
- `ssh-rsa`
- `ssh-dss`

Certificate types (`…-cert-v01@openssh.com`), security keys (`sk-…@openssh.com`), and marker lines
(`@cert-authority`, `@revoked`) are rejected.

### What the checks verify

- The key field is valid base64, and the decoded key blob names the same algorithm as the entry and carries exactly
  that algorithm's components.
- The key is valid for its algorithm: EC points lie on their curve and are not the point at infinity, and DSA public
  values lie in their subgroup.
- OpenSSH would accept the key: RSA moduli are 1024 to 16384 bits, with a public exponent above 1.

### Host field

The first field of a full line names the hosts. It may be one host or a comma-separated list
(`127.0.0.1,example.com`) of:

- hostnames (`example.com`, `localhost`);
- IPv4 and IPv6 addresses (`10.0.0.1`, `2001:db8::1`);
- bracketed hosts with a port, as OpenSSH writes hosts on a port other than 22 (`[example.com]:2222`,
  `[2001:db8::1]:443`);
- IPv4 addresses with a port (`10.0.0.1:2222`);
- hashed hosts (`|1|<base64 salt>|<base64 hash>`).

Wildcard patterns (`*.example.com`) and negations (`!host`) are not accepted.

---

## Reference

### Algorithms

| Namespace | `AsymmetricKeyType` | OpenSSH name |
|-----------|---------------------|--------------|
| `AsymmetricCryptography.EdDSA.Ed25519` | `.ed25519` | `ssh-ed25519` |
| `AsymmetricCryptography.EdDSA.Ed448` | `.ed448` | — |
| `AsymmetricCryptography.ECDSA.P256` / `P384` / `P521` | `.ecdsaP256` / `.ecdsaP384` / `.ecdsaP521` | `ecdsa-sha2-nistp256` / `384` / `521` |
| `AsymmetricCryptography.RSA` | `.rsa` | `ssh-rsa` |
| `AsymmetricCryptography.MLDSA.MLDSA44` / `MLDSA65` / `MLDSA87` | `.mlDSA44` / `.mlDSA65` / `.mlDSA87` | — |
| `AsymmetricCryptography.SLHDSA.SHA2_128s` … `SHAKE_256f` (12 parameter sets) | `.slhDSA_SHA2_128s` … `.slhDSA_SHAKE_256f` | — |

`AsymmetricKeyType.openSSHName` returns the OpenSSH name, or `nil` when OpenSSH does not define the key type. A single
RSA key serves both PKCS#1 v1.5 and PSS signatures. SLH-DSA `s` parameter sets make small signatures slowly; `f`
sets sign fast with larger signatures.

ML-DSA and SLH-DSA need OpenSSL 3.5 or later. SwiftSFTP compiles its pinned OpenSSL sources on every supported
platform, so every algorithm is available on Apple platforms, Linux, and Android. `AsymmetricKeyType.isAvailable`
reports availability at runtime.

### Formats

| Format | Private key | Public key | Key types |
|--------|-------------|------------|-----------|
| `.openSSH` | `BEGIN OPENSSH PRIVATE KEY` | `ssh-ed25519 AAAA… [comment]` | Ed25519, ECDSA, RSA |
| `.pkcs8` | `BEGIN PRIVATE KEY` / `BEGIN ENCRYPTED PRIVATE KEY` | — | all |
| `.pem` | `BEGIN RSA PRIVATE KEY` / `BEGIN EC PRIVATE KEY` | `BEGIN PUBLIC KEY` (SubjectPublicKeyInfo) | private: RSA, ECDSA; public: all |
| DER | `derRepresentation` (PKCS#8) | `derRepresentation` (SubjectPublicKeyInfo) | all |

Parsing accepts every format above. Encoding encrypts as described in
[Encoding the private key](#encoding-the-private-key); parsing also reads the extra OpenSSH ciphers listed in
[What `PrivateKey(string:passphrase:)` reads](#what-privatekeystringpassphrase-reads).

### Errors

Key generation, parsing, and encoding throw `AsymmetricCryptographyError`:

| Case | Thrown when |
|------|-------------|
| `invalidKeyData` | The input is not a well-formed, valid key. |
| `passphraseRequired` | The key is encrypted and the passphrase is `nil` or empty. |
| `incorrectPassphrase` | The passphrase does not decrypt the key. |
| `unsupportedEncryption(_:)` | An OpenSSH key uses an unsupported cipher or KDF, or more than 1024 bcrypt rounds. |
| `unsupportedAlgorithm(_:)` | The key's algorithm is not supported; carries its name, such as `X25519` or `ssh-dss`. |
| `unsupportedPrivateKeyFormat(_:_:)` / `unsupportedPublicKeyFormat(_:_:)` | The key type has no encoding in that format. |
| `keyTypeMismatch(expected:actual:)` | `derivePublicKey(from:)` received a key of another algorithm. |
| `invalidKeySize(_:)` | `RSA.generateKeyPair(bits:)` received a size outside 2048…16384. |
| `openSSLFailure(_:)` | OpenSSL failed unexpectedly; carries its error queue. |

The `Bool` checks never throw.

### Deprecated API

| Deprecated | Replacement |
|------------|-------------|
| `SwiftSFTP_Curve25519.generateKeyPairInOpenSSHFormat()` | `AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair()`, then `encode(format: .openSSH)` |
| `SwiftSFTP_Curve25519.generatePublicKeyFromPrivateKey(openSSHFormat:)` | `PrivateKey(string:).publicKey.encode(format: .openSSH)` |
| `OpenSSHKeyPair` | `AsymmetricKeyPair` |
| `isValid_PrivateKey(password:)`, `isValid_RSA_PrivateKey(password:)`, … | The `passphrase:` variants |

### What these APIs do not check

- Whether a server will accept a key for user authentication (its `authorized_keys`).
- Whether a host key belongs to the host you mean to connect to.
- Certificates, their expiry, or revocation.
- Key strength beyond OpenSSH's own rules — for example, whether a 2048-bit RSA key is strong enough for you.

Connection-time trust is decided by `SFTPClient`'s `HostKeyAcceptance` setting and by the server's own authorization.
