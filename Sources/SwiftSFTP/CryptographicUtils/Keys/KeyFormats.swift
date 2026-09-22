import Foundation

/// Text encodings for public keys. ``PublicKey/derRepresentation`` holds the binary DER form.
public enum PublicKeyFormat: Int, CaseIterable, Codable, Sendable {
    /// One-line OpenSSH public key (`ssh-ed25519 AAAA…`), as used in `authorized_keys`. Only key types with an
    /// ``AsymmetricKeyType/openSSHName`` have one.
    case openSSH
    /// PEM-encoded SubjectPublicKeyInfo (`-----BEGIN PUBLIC KEY-----`).
    case pem
}

/// Text encodings for private keys. ``PrivateKey/derRepresentation`` holds the binary PKCS#8 DER form.
public enum PrivateKeyFormat: Int, CaseIterable, Codable, Sendable {
    /// OpenSSH private key (`-----BEGIN OPENSSH PRIVATE KEY-----`), encrypted with aes256-ctr and bcrypt when a
    /// passphrase is given, as `ssh-keygen` does. Only key types with an ``AsymmetricKeyType/openSSHName`` have one.
    case openSSH
    /// Algorithm-specific PEM (`-----BEGIN RSA PRIVATE KEY-----`, `-----BEGIN EC PRIVATE KEY-----`); only RSA and
    /// ECDSA define one. Encryption uses the legacy PEM scheme with AES-256-CBC; prefer ``pkcs8`` for new keys.
    case pem
    /// PEM-encoded PKCS#8 (`-----BEGIN PRIVATE KEY-----`, or `-----BEGIN ENCRYPTED PRIVATE KEY-----` with PBES2 and
    /// AES-256-CBC when a passphrase is given).
    case pkcs8
}
