import Foundation

/// One private-key candidate for multi-key public-key authentication.
struct PrivateKeyAuthCandidate: Equatable, Sendable {
    /// The unencrypted private key as OpenSSH text, as libssh2 reads it.
    let keyData: String
    /// The key's algorithm family.
    let algorithm: SSHUserKeyAlgorithm
    /// Original position among user-supplied keys (stable secondary sort).
    let originalIndex: Int
}

/// Orders and filters private keys using the server's `server-sig-algs` preference.
///
/// Behavior (OpenSSH-like):
/// - When `serverSigAlgs` is present, only keys that can produce a listed signature algorithm are kept, and they are
/// ordered by the server's preference (earlier = try first).
/// - When `serverSigAlgs` is absent, keys are ordered by ``SSHUserKeyAlgorithm/defaultSignaturePreference``.
/// - Within the same preference rank, the user's original order is preserved.
enum PrivateKeyAuthPlanner {
    /// Builds candidates from `keys`, in order, leaving out keys SSH user authentication cannot use.
    static func candidates(from keys: [PrivateKey]) -> [PrivateKeyAuthCandidate] {
        keys.enumerated().compactMap { index, key in
            guard let algorithm = SSHUserKeyAlgorithm(privateKey: key),
                  let keyData = try? key.encode(format: .openSSH) else { return nil }
            return PrivateKeyAuthCandidate(keyData: keyData, algorithm: algorithm, originalIndex: index)
        }
    }

    /// Filters and sorts candidates for authentication attempts.
    ///
    /// - Parameters:
    ///   - candidates: Keys supplied by the user.
    ///   - serverSigAlgs: From ``SessionServerSignAlgorithms(session:)``, or `nil`.
    /// - Returns: Candidates to try, in attempt order.
    static func plan(
        candidates: [PrivateKeyAuthCandidate],
        serverSigAlgs: [String]?
    ) -> [PrivateKeyAuthCandidate] {
        let preference = serverSigAlgs ?? SSHUserKeyAlgorithm.defaultSignaturePreference
        let strictFilter = serverSigAlgs != nil

        let ranked: [(candidate: PrivateKeyAuthCandidate, rank: Int)] = candidates.compactMap { candidate in
            if let index = candidate.algorithm.preferenceIndex(in: preference) {
                return (candidate, index)
            }
            // Without a server list, a family missing from the default list is tried after the preferred ones; with
            // one, the server cannot verify the key's signatures.
            return strictFilter ? nil : (candidate, preference.count)
        }

        return ranked
            .sorted {
                if $0.rank != $1.rank {
                    return $0.rank < $1.rank
                }
                return $0.candidate.originalIndex < $1.candidate.originalIndex
            }
            .map(\.candidate)
    }
}
