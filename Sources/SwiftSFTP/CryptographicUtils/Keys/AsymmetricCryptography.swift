import Foundation

/// OpenSSL-backed generation, import, and export of asymmetric signature keys.
///
/// Each supported algorithm is a namespace type conforming to ``AsymmetricAlgorithm``:
///
/// ```swift
/// let pair = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair()
/// let authorizedKey = try pair.publicKey.encode(format: .openSSH)
/// let keyFile = try pair.privateKey.encode(format: .openSSH, passphrase: "passphrase")
/// ```
///
/// Keys of every supported algorithm are held by ``PrivateKey`` and ``PublicKey``, which parse and encode the formats
/// OpenSSL and OpenSSH define for them (see ``PrivateKeyFormat`` and ``PublicKeyFormat``).
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
        try AsymmetricKeyPair(privateKey: PrivateKey(key: OpenSSLKey.generate(keyType), type: keyType))
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
            let key = try OpenSSLKey.generate(keyType, rsaBits: bits)
            return try AsymmetricKeyPair(privateKey: PrivateKey(key: key, type: keyType))
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
