import Foundation

/// OpenSSL-backed asymmetric key generation, import, and export.
///
/// Each algorithm is a namespace type conforming to ``AsymmetricAlgorithm``, for example
/// `AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair()`. Keys of any supported algorithm are held by ``PrivateKey``
/// and ``PublicKey``, which parse and encode every format OpenSSL (and OpenSSH) defines for them.
public enum AsymmetricCryptography {
}

// MARK: - Algorithms

/// An asymmetric signature algorithm whose keys SwiftSFTP can generate, import, and export.
public protocol AsymmetricAlgorithm: Sendable {
    /// The key type this algorithm generates and accepts.
    static var keyType: AsymmetricKeyType { get }

    /// Generates a new random key pair.
    static func generateKeyPair() throws -> AsymmetricKeyPair

    /// Returns the key pair for `privateKey`, which must be of this algorithm's ``keyType``.
    static func derivePublicKey(from privateKey: PrivateKey) throws -> AsymmetricKeyPair
}

public extension AsymmetricAlgorithm {
    static func generateKeyPair() throws -> AsymmetricKeyPair {
        try AsymmetricKeyPair(privateKey: PrivateKey(key: OpenSSLKey.generate(keyType)))
    }

    static func derivePublicKey(from privateKey: PrivateKey) throws -> AsymmetricKeyPair {
        guard privateKey.type == keyType else {
            throw AsymmetricCryptographyError.keyTypeMismatch(expected: keyType, actual: privateKey.type)
        }
        return AsymmetricKeyPair(privateKey: privateKey)
    }
}

public extension AsymmetricCryptography {
    /// Edwards-curve Digital Signature Algorithm (RFC 8032).
    enum EdDSA {
        /// Ed25519 (`ssh-ed25519`).
        public enum Ed25519: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.ed25519
        }

        /// Ed448. OpenSSH does not support Ed448 keys.
        public enum Ed448: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.ed448
        }
    }

    /// Elliptic Curve Digital Signature Algorithm over the NIST prime curves.
    enum ECDSA {
        /// ECDSA over P-256 (`ecdsa-sha2-nistp256`).
        public enum P256: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.ecdsaP256
        }

        /// ECDSA over P-384 (`ecdsa-sha2-nistp384`).
        public enum P384: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.ecdsaP384
        }

        /// ECDSA over P-521 (`ecdsa-sha2-nistp521`).
        public enum P521: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.ecdsaP521
        }
    }

    /// RSA (`ssh-rsa`). One key serves both PKCS#1 v1.5 and PSS signatures; the padding is a signing choice.
    enum RSA: AsymmetricAlgorithm {
        public static let keyType = AsymmetricKeyType.rsa

        /// Modulus size used by ``generateKeyPair()``, matching `ssh-keygen`'s default.
        public static let defaultBits = 3072

        /// Smallest modulus size ``generateKeyPair(bits:)`` accepts.
        public static let minimumBits = 2048

        /// Largest modulus size ``generateKeyPair(bits:)`` accepts, matching OpenSSH's limit.
        public static let maximumBits = 16384

        /// Generates a new RSA key pair with a ``defaultBits`` modulus.
        public static func generateKeyPair() throws -> AsymmetricKeyPair {
            try generateKeyPair(bits: defaultBits)
        }

        /// Generates a new RSA key pair with a modulus of `bits` bits.
        public static func generateKeyPair(bits: Int) throws -> AsymmetricKeyPair {
            guard (minimumBits ... maximumBits).contains(bits) else {
                throw AsymmetricCryptographyError.invalidKeySize(bits)
            }
            return try AsymmetricKeyPair(privateKey: PrivateKey(key: OpenSSLKey.generate(keyType, rsaBits: bits)))
        }
    }

    /// Module-Lattice-Based Digital Signature Algorithm (FIPS 204). Requires OpenSSL 3.5 or later at runtime.
    enum MLDSA {
        /// ML-DSA-44 (NIST security category 2).
        public enum MLDSA44: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.mlDSA44
        }

        /// ML-DSA-65 (NIST security category 3).
        public enum MLDSA65: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.mlDSA65
        }

        /// ML-DSA-87 (NIST security category 5).
        public enum MLDSA87: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.mlDSA87
        }
    }

    /// Stateless Hash-Based Digital Signature Algorithm (FIPS 205). Requires OpenSSL 3.5 or later at runtime.
    ///
    /// `s` parameter sets produce small signatures slowly; `f` parameter sets sign fast with larger signatures.
    enum SLHDSA {
        /// SLH-DSA-SHA2-128s.
        public enum SHA2_128s: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.slhDSA_SHA2_128s
        }

        /// SLH-DSA-SHA2-128f.
        public enum SHA2_128f: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.slhDSA_SHA2_128f
        }

        /// SLH-DSA-SHA2-192s.
        public enum SHA2_192s: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.slhDSA_SHA2_192s
        }

        /// SLH-DSA-SHA2-192f.
        public enum SHA2_192f: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.slhDSA_SHA2_192f
        }

        /// SLH-DSA-SHA2-256s.
        public enum SHA2_256s: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.slhDSA_SHA2_256s
        }

        /// SLH-DSA-SHA2-256f.
        public enum SHA2_256f: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.slhDSA_SHA2_256f
        }

        /// SLH-DSA-SHAKE-128s.
        public enum SHAKE_128s: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.slhDSA_SHAKE_128s
        }

        /// SLH-DSA-SHAKE-128f.
        public enum SHAKE_128f: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.slhDSA_SHAKE_128f
        }

        /// SLH-DSA-SHAKE-192s.
        public enum SHAKE_192s: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.slhDSA_SHAKE_192s
        }

        /// SLH-DSA-SHAKE-192f.
        public enum SHAKE_192f: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.slhDSA_SHAKE_192f
        }

        /// SLH-DSA-SHAKE-256s.
        public enum SHAKE_256s: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.slhDSA_SHAKE_256s
        }

        /// SLH-DSA-SHAKE-256f.
        public enum SHAKE_256f: AsymmetricAlgorithm {
            public static let keyType = AsymmetricKeyType.slhDSA_SHAKE_256f
        }
    }
}

// MARK: - Key types

/// The algorithm and parameters of an asymmetric key.
public enum AsymmetricKeyType: String, CaseIterable, Codable, Sendable {
    case ed25519
    case ed448
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521
    case rsa
    case mlDSA44
    case mlDSA65
    case mlDSA87
    case slhDSA_SHA2_128s
    case slhDSA_SHA2_128f
    case slhDSA_SHA2_192s
    case slhDSA_SHA2_192f
    case slhDSA_SHA2_256s
    case slhDSA_SHA2_256f
    case slhDSA_SHAKE_128s
    case slhDSA_SHAKE_128f
    case slhDSA_SHAKE_192s
    case slhDSA_SHAKE_192f
    case slhDSA_SHAKE_256s
    case slhDSA_SHAKE_256f

    /// The OpenSSH key type name (for example `ssh-ed25519`), or `nil` when OpenSSH does not support the algorithm.
    public var openSSHName: String? {
        switch self {
        case .ed25519: "ssh-ed25519"
        case .ecdsaP256: "ecdsa-sha2-nistp256"
        case .ecdsaP384: "ecdsa-sha2-nistp384"
        case .ecdsaP521: "ecdsa-sha2-nistp521"
        case .rsa: "ssh-rsa"
        default: nil
        }
    }

    /// Whether the linked OpenSSL can generate and parse keys of this type.
    ///
    /// ML-DSA and SLH-DSA need OpenSSL 3.5 or later, which a system OpenSSL on Linux may not provide.
    public var isAvailable: Bool {
        OpenSSLKey.isAvailable(self)
    }

    /// The key type named `openSSHName` (for example `ssh-ed25519`), or `nil` when it is not a supported plain key.
    init?(openSSHName: String) {
        guard let type = Self.allCases.first(where: { $0.openSSHName == openSSHName }) else { return nil }
        self = type
    }
}

// MARK: - Formats

/// Text encodings for public keys. ``PublicKey/derRepresentation`` holds the binary DER form.
public enum PublicKeyFormat: Int, CaseIterable, Codable, Sendable {
    /// One-line OpenSSH public key (`ssh-ed25519 AAAA…`), as used in `authorized_keys`.
    case openSSH
    /// PEM-encoded SubjectPublicKeyInfo (`-----BEGIN PUBLIC KEY-----`).
    case pem
}

/// Text encodings for private keys. ``PrivateKey/derRepresentation`` holds the binary PKCS#8 DER form.
public enum PrivateKeyFormat: Int, CaseIterable, Codable, Sendable {
    /// OpenSSH private key (`-----BEGIN OPENSSH PRIVATE KEY-----`); encrypted with aes256-ctr and bcrypt when a
    /// passphrase is given, as `ssh-keygen` does.
    case openSSH
    /// Algorithm-specific PEM (`-----BEGIN RSA PRIVATE KEY-----`, `-----BEGIN EC PRIVATE KEY-----`); only RSA and
    /// ECDSA define one. Encryption uses the legacy PEM scheme with AES-256-CBC; prefer ``pkcs8`` for new keys.
    case pem
    /// PEM-encoded PKCS#8 (`-----BEGIN PRIVATE KEY-----`, or `-----BEGIN ENCRYPTED PRIVATE KEY-----` with PBES2 and
    /// AES-256-CBC when a passphrase is given).
    case pkcs8
}

// MARK: - Keys

/// An asymmetric public key of any supported algorithm.
public struct PublicKey: Sendable, Hashable, Codable {
    /// The key as DER-encoded SubjectPublicKeyInfo.
    public let derRepresentation: Data
    /// The key's algorithm and parameters.
    public let type: AsymmetricKeyType

    /// Creates a public key from DER-encoded SubjectPublicKeyInfo.
    public init(derRepresentation: Data) throws {
        try self.init(key: OpenSSLKey(publicKeyDER: derRepresentation))
    }

    /// Parses a one-line OpenSSH public key (`type base64 [comment]`) or a PEM `PUBLIC KEY`.
    public init(string: String) throws {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("-----BEGIN") {
            try self.init(key: OpenSSLKey(publicKeyPEM: text))
        }
        else {
            try self.init(key: OpenSSHKeyCodec.decodePublicKey(text))
        }
    }

    init(key: OpenSSLKey) throws {
        type = try key.keyType()
        derRepresentation = try key.publicKeyDER()
    }

    /// Encodes the key as text in `format`.
    public func encode(format: PublicKeyFormat) throws -> String {
        let key = try OpenSSLKey(publicKeyDER: derRepresentation)
        switch format {
        case .openSSH:
            return try OpenSSHKeyCodec.encodePublicKey(key, type: type)
        case .pem:
            return try key.publicKeyPEM()
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(derRepresentation: container.decode(Data.self))
        }
        catch let error as AsymmetricCryptographyError {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(error)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(derRepresentation)
    }
}

/// An asymmetric private key of any supported algorithm, with its public key.
public struct PrivateKey: Sendable, Hashable, Codable {
    /// The key as unencrypted DER-encoded PKCS#8.
    public let derRepresentation: Data
    /// The key's algorithm and parameters.
    public let type: AsymmetricKeyType
    /// The public key matching this private key.
    public let publicKey: PublicKey

    /// Creates a private key from DER-encoded PKCS#8, or from an algorithm-specific DER key (PKCS#1 RSA, SEC 1 EC).
    public init(derRepresentation: Data) throws {
        try self.init(key: OpenSSLKey(privateKeyDER: derRepresentation))
    }

    /// Parses an OpenSSH, PKCS#8, or algorithm-specific PEM private key, decrypting it with `passphrase` when it is
    /// encrypted.
    public init(string: String, passphrase: String? = nil) throws {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let passphrase = passphrase.flatMap { $0.isEmpty ? nil : $0 }
        if text.hasPrefix(OpenSSHKeyCodec.privateKeyHeader) {
            try self.init(key: OpenSSHKeyCodec.decodePrivateKey(text, passphrase: passphrase))
        }
        else {
            try self.init(key: OpenSSLKey(privateKeyPEM: text, passphrase: passphrase))
        }
    }

    init(key: OpenSSLKey) throws {
        type = try key.keyType()
        derRepresentation = try key.privateKeyDER()
        publicKey = try PublicKey(key: key)
    }

    /// Encodes the key as text in `format`, encrypted with `passphrase` unless it is `nil` or empty.
    public func encode(format: PrivateKeyFormat, passphrase: String? = nil) throws -> String {
        let key = try OpenSSLKey(privateKeyDER: derRepresentation)
        let passphrase = passphrase.flatMap { $0.isEmpty ? nil : $0 }
        switch format {
        case .openSSH:
            return try OpenSSHKeyCodec.encodePrivateKey(key, type: type, passphrase: passphrase)
        case .pem:
            guard type == .rsa || type == .ecdsaP256 || type == .ecdsaP384 || type == .ecdsaP521 else {
                throw AsymmetricCryptographyError.unsupportedPrivateKeyFormat(format, type)
            }
            return try key.traditionalPrivateKeyPEM(passphrase: passphrase)
        case .pkcs8:
            return try key.pkcs8PrivateKeyPEM(passphrase: passphrase)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(derRepresentation: container.decode(Data.self))
        }
        catch let error as AsymmetricCryptographyError {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(error)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(derRepresentation)
    }
}

/// A private key together with its public key.
public struct AsymmetricKeyPair: Sendable, Hashable, Codable {
    /// The public half of the pair.
    public let publicKey: PublicKey
    /// The private half of the pair.
    public let privateKey: PrivateKey

    /// Creates the key pair for `privateKey`.
    public init(privateKey: PrivateKey) {
        self.privateKey = privateKey
        publicKey = privateKey.publicKey
    }

    /// The key pair's algorithm and parameters.
    public var type: AsymmetricKeyType {
        privateKey.type
    }

    private enum CodingKeys: String, CodingKey {
        case publicKey
        case privateKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let privateKey = try container.decode(PrivateKey.self, forKey: .privateKey)
        let publicKey = try container.decode(PublicKey.self, forKey: .publicKey)
        guard publicKey == privateKey.publicKey else {
            throw DecodingError.dataCorruptedError(
                forKey: .publicKey,
                in: container,
                debugDescription: "The public key does not match the private key."
            )
        }
        self.init(privateKey: privateKey)
    }
}

// MARK: - Errors

/// Errors thrown by ``AsymmetricCryptography`` key generation, import, and export.
public enum AsymmetricCryptographyError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The key's algorithm is not one SwiftSFTP supports, or the linked OpenSSL lacks it; carries OpenSSL's name.
    case unsupportedAlgorithm(String)
    /// The key type cannot be encoded as this private key format.
    case unsupportedPrivateKeyFormat(PrivateKeyFormat, AsymmetricKeyType)
    /// The key type cannot be encoded as this public key format.
    case unsupportedPublicKeyFormat(PublicKeyFormat, AsymmetricKeyType)
    /// The key is not of the algorithm the operation requires.
    case keyTypeMismatch(expected: AsymmetricKeyType, actual: AsymmetricKeyType)
    /// The requested key size is out of range.
    case invalidKeySize(Int)
    /// The input is not a well-formed key.
    case invalidKeyData
    /// The key is encrypted and no passphrase was given.
    case passphraseRequired
    /// The key could not be decrypted with the given passphrase.
    case incorrectPassphrase
    /// The OpenSSH key is encrypted with a cipher or KDF SwiftSFTP does not support; carries its name.
    case unsupportedEncryption(String)
    /// OpenSSL failed unexpectedly; carries its error queue.
    case openSSLFailure(String)

    public var description: String {
        switch self {
        case let .unsupportedAlgorithm(name):
            "Unsupported key algorithm: \(name)"
        case let .unsupportedPrivateKeyFormat(format, type):
            "\(type) private keys cannot be encoded as \(format)"
        case let .unsupportedPublicKeyFormat(format, type):
            "\(type) public keys cannot be encoded as \(format)"
        case let .keyTypeMismatch(expected, actual):
            "Expected a \(expected) key, got \(actual)"
        case let .invalidKeySize(bits):
            "Invalid key size: \(bits) bits"
        case .invalidKeyData:
            "Invalid key data"
        case .passphraseRequired:
            "The key is encrypted; a passphrase is required"
        case .incorrectPassphrase:
            "Incorrect passphrase"
        case let .unsupportedEncryption(name):
            "Unsupported key encryption: \(name)"
        case let .openSSLFailure(message):
            "OpenSSL failure: \(message)"
        }
    }
}
