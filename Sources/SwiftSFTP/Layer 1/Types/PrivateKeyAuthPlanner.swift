import Foundation

/// One private-key candidate for multi-key public-key authentication.
struct PrivateKeyAuthCandidate: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case memory(String)
        case file(URL)
    }

    let source: Source
    let passphrase: String?
    /// Classified algorithm, or `nil` when the key could not be typed (still may be tried last).
    let algorithm: SSHUserKeyAlgorithm?
    /// Original position among user-supplied keys (stable secondary sort).
    let originalIndex: Int
}

/// Orders and filters private keys using the server's `server-sig-algs` preference.
///
/// Behavior (OpenSSH-like):
/// - When `serverSigAlgs` is present, only keys that can produce a listed signature algorithm are kept, and they are
/// ordered by the server's preference (earlier = try first).
/// - When `serverSigAlgs` is absent, all classifiable keys are ordered by
///   ``SSHUserKeyAlgorithm/defaultSignaturePreference``; unclassifiable keys are appended last.
/// - Within the same preference rank, the user's original order is preserved.
enum PrivateKeyAuthPlanner {
    /// Builds ordered candidates from a ``PrivateKeySet``.
    static func candidates(from set: PrivateKeySet) -> [PrivateKeyAuthCandidate] {
        var result: [PrivateKeyAuthCandidate] = []
        var index = 0

        for item in set.strings {
            let algorithm = SSHUserKeyAlgorithm.detect(
                from: item.representation,
                passphrase: item.passphrase
            )
            result.append(
                PrivateKeyAuthCandidate(
                    source: .memory(item.representation),
                    passphrase: item.passphrase,
                    algorithm: algorithm,
                    originalIndex: index
                )
            )
            index += 1
        }

        for item in set.files {
            let algorithm: SSHUserKeyAlgorithm? = if let data = try? Data(contentsOf: item.file),
                                                     let text = String(data: data, encoding: .utf8) {
                SSHUserKeyAlgorithm.detect(from: text, passphrase: item.passphrase)
            }
            else {
                nil
            }
            result.append(
                PrivateKeyAuthCandidate(
                    source: .file(item.file),
                    passphrase: item.passphrase,
                    algorithm: algorithm,
                    originalIndex: index
                )
            )
            index += 1
        }

        return result
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

        struct Ranked {
            let candidate: PrivateKeyAuthCandidate
            let rank: Int
        }

        var ranked: [Ranked] = []
        ranked.reserveCapacity(candidates.count)

        for candidate in candidates {
            if let algorithm = candidate.algorithm {
                if let index = algorithm.preferenceIndex(in: preference) {
                    ranked.append(Ranked(candidate: candidate, rank: index))
                }
                else if !strictFilter {
                    // Known type but not in default list: try after preferred types.
                    ranked.append(Ranked(candidate: candidate, rank: preference.count))
                }
                // strictFilter + no match: drop incompatible key
            }
            else if !strictFilter {
                // Unclassified: try last when we cannot filter against the server.
                ranked.append(Ranked(candidate: candidate, rank: preference.count + 1))
            }
            else {
                // Server listed algorithms; unclassifiable keys still worth a try at the end (e.g. encrypted OpenSSH
                // that failed local type detection).
                ranked.append(Ranked(candidate: candidate, rank: preference.count + 1))
            }
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
