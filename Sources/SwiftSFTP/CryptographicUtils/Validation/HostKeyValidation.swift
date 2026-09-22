import Foundation

/// OpenSSH `known_hosts` host key validation for `String` values.
///
/// A host key is valid when its blob names the line's algorithm, carries exactly that algorithm's components, holds a
/// valid key (for example an EC point on its curve), and meets OpenSSH's rules (see ``OpenSSHKeyPolicy``).
public extension String {
    /// Returns whether the string is a valid shorthand host key (`algorithm base64-key`) for RSA, ECDSA, Ed25519, or
    /// DSA.
    var isValid_ShortHandHostKey: Bool {
        let fields = knownHostsFields
        guard fields.count == 2,
              let algorithm = SSHHostKeyAlgorithm(rawValue: fields[0]) else { return false }
        return algorithm.validates(base64: fields[1])
    }

    /// Returns whether the string is a valid full OpenSSH `known_hosts` line (`host algorithm base64-key [comment]`)
    /// for RSA, ECDSA, Ed25519, or DSA. Marker lines (`@cert-authority`, `@revoked`) are not accepted.
    var isValid_HostKey: Bool {
        let fields = knownHostsFields
        guard fields.count >= 3,
              TCPLocation.isValidKnownHostsHostField(fields[0]),
              let algorithm = SSHHostKeyAlgorithm(rawValue: fields[1]) else { return false }
        return algorithm.validates(base64: fields[2])
    }
}

private extension String {
    /// The whitespace-separated fields of a `known_hosts` entry; trailing fields are the optional comment.
    var knownHostsFields: [String] {
        split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// Host key algorithms SwiftSFTP accepts in `known_hosts` entries, named as they appear on the wire.
enum SSHHostKeyAlgorithm: String, Sendable {
    case rsa = "ssh-rsa"
    case dsa = "ssh-dss"
    case ecdsaP256 = "ecdsa-sha2-nistp256"
    case ecdsaP384 = "ecdsa-sha2-nistp384"
    case ecdsaP521 = "ecdsa-sha2-nistp521"
    case ed25519 = "ssh-ed25519"

    /// Returns whether `key` is the base64 public key blob of a valid key of this algorithm that OpenSSH accepts.
    func validates(base64 key: String) -> Bool {
        guard let blob = Data(base64Encoded: key) else { return false }
        if self == .dsa {
            return Self.validatesDSA(blob: blob)
        }
        guard let openSSLKey = try? OpenSSHKeyCodec.decodePublicKey(blob: blob, named: rawValue),
              let publicKey = try? PublicKey(importing: openSSLKey) else { return false }
        return OpenSSHKeyPolicy.accepts(publicKey)
    }

    /// Returns whether `blob` is a valid `ssh-dss` key.
    ///
    /// DSA is not an ``AsymmetricKeyType``, since current OpenSSH no longer supports it, so its blob is read here: the
    /// domain parameters p, q, g and the public value, which must lie in the order-q subgroup.
    private static func validatesDSA(blob: Data) -> Bool {
        var reader = SSHWireReader(blob)
        guard reader.readString() == dsa.rawValue,
              let p = reader.readMPInt(),
              let q = reader.readMPInt(),
              let g = reader.readMPInt(),
              let publicValue = reader.readMPInt(),
              reader.isAtEnd,
              ![p, q, g, publicValue].contains(where: \.isEmpty),
              let key = try? OpenSSLKey(dsaP: p, q: q, g: g, publicValue: publicValue) else { return false }
        return (try? key.checkPublicKey()) != nil
    }
}
