@testable import SwiftSFTP
import Foundation
import Testing

@Suite("PrivateKeyAuthPlanner")
struct PrivateKeyAuthPlannerTests {
    private func memory(
        _ text: String,
        index: Int,
        algorithm: SSHUserKeyAlgorithm
    ) -> PrivateKeyAuthCandidate {
        .init(keyData: text, algorithm: algorithm, originalIndex: index)
    }

    // MARK: - plan()

    @Test("orders by server preference when server-sig-algs is present")
    func ordersByServerPreference() {
        let candidates = [
            memory("rsa", index: 0, algorithm: .rsa),
            memory("ed", index: 1, algorithm: .ed25519),
            memory("p256", index: 2, algorithm: .ecdsaP256),
        ]
        let server = [
            "ecdsa-sha2-nistp256",
            "ssh-ed25519",
            "rsa-sha2-512",
            "rsa-sha2-256",
        ]
        let planned = PrivateKeyAuthPlanner.plan(candidates: candidates, serverSigAlgs: server)
        #expect(planned.map(\.algorithm) == [.ecdsaP256, .ed25519, .rsa])
    }

    @Test("filters algorithms absent from server-sig-algs")
    func filtersIncompatibleAlgorithms() {
        let candidates = [
            memory("rsa", index: 0, algorithm: .rsa),
            memory("ed", index: 1, algorithm: .ed25519),
            memory("p384", index: 2, algorithm: .ecdsaP384),
        ]
        let server = ["ssh-ed25519", "rsa-sha2-512", "rsa-sha2-256"]
        let planned = PrivateKeyAuthPlanner.plan(candidates: candidates, serverSigAlgs: server)
        #expect(planned.map(\.algorithm) == [.ed25519, .rsa])
    }

    @Test("drops every candidate when none match server-sig-algs")
    func dropsAllWhenNoneMatch() {
        let candidates = [
            memory("ed", index: 0, algorithm: .ed25519),
            memory("p256", index: 1, algorithm: .ecdsaP256),
        ]
        let server = ["rsa-sha2-512", "rsa-sha2-256"]
        let planned = PrivateKeyAuthPlanner.plan(candidates: candidates, serverSigAlgs: server)
        #expect(planned.isEmpty)
    }

    @Test("RSA matches rsa-sha2 family in server-sig-algs")
    func rsaMatchesSha2Family() {
        let candidates = [memory("rsa", index: 0, algorithm: .rsa)]
        let server = ["rsa-sha2-512", "rsa-sha2-256"]
        let planned = PrivateKeyAuthPlanner.plan(candidates: candidates, serverSigAlgs: server)
        #expect(planned.count == 1)
        #expect(planned[0].algorithm == .rsa)
    }

    @Test("RSA also matches legacy ssh-rsa alone")
    func rsaMatchesLegacySSHRsa() {
        let candidates = [memory("rsa", index: 0, algorithm: .rsa)]
        let server = ["ssh-rsa"]
        let planned = PrivateKeyAuthPlanner.plan(candidates: candidates, serverSigAlgs: server)
        #expect(planned.map(\.algorithm) == [.rsa])
    }

    @Test("ecdsa curves are distinguished in filter and order")
    func ecdsaCurvesDistinguished() {
        let candidates = [
            memory("p521", index: 0, algorithm: .ecdsaP521),
            memory("p256", index: 1, algorithm: .ecdsaP256),
            memory("p384", index: 2, algorithm: .ecdsaP384),
        ]
        let server = [
            "ecdsa-sha2-nistp384",
            "ecdsa-sha2-nistp521",
            "ecdsa-sha2-nistp256",
        ]
        let planned = PrivateKeyAuthPlanner.plan(candidates: candidates, serverSigAlgs: server)
        #expect(planned.map(\.algorithm) == [.ecdsaP384, .ecdsaP521, .ecdsaP256])
    }

    @Test("without server-sig-algs uses default preference and keeps all classifiable keys")
    func defaultPreferenceWithoutServerList() {
        let candidates = [
            memory("rsa", index: 0, algorithm: .rsa),
            memory("ed", index: 1, algorithm: .ed25519),
            memory("p256", index: 2, algorithm: .ecdsaP256),
            memory("p521", index: 3, algorithm: .ecdsaP521),
            memory("p384", index: 4, algorithm: .ecdsaP384),
        ]
        let planned = PrivateKeyAuthPlanner.plan(candidates: candidates, serverSigAlgs: nil)
        #expect(planned.map(\.algorithm) == [.ed25519, .ecdsaP256, .ecdsaP384, .ecdsaP521, .rsa])
    }

    @Test("preserves user order within the same algorithm rank")
    func preservesOrderWithinRank() {
        let candidates = [
            memory("rsa-a", index: 0, algorithm: .rsa),
            memory("rsa-b", index: 1, algorithm: .rsa),
            memory("ed", index: 2, algorithm: .ed25519),
        ]
        let server = ["ssh-ed25519", "rsa-sha2-512"]
        let planned = PrivateKeyAuthPlanner.plan(candidates: candidates, serverSigAlgs: server)
        #expect(planned.map(\.originalIndex) == [2, 0, 1])
    }

    @Test("empty candidate list yields empty plan")
    func emptyCandidates() {
        #expect(PrivateKeyAuthPlanner.plan(candidates: [], serverSigAlgs: nil).isEmpty)
        #expect(
            PrivateKeyAuthPlanner.plan(candidates: [], serverSigAlgs: ["ssh-ed25519"]).isEmpty
        )
    }

    @Test("plan preserves the key data of each candidate")
    func planPreservesKeyData() {
        let candidates = [
            memory("rsa-body", index: 0, algorithm: .rsa),
            memory("ed-body", index: 1, algorithm: .ed25519),
        ]
        let planned = PrivateKeyAuthPlanner.plan(
            candidates: candidates,
            serverSigAlgs: ["ssh-ed25519", "rsa-sha2-512"]
        )
        #expect(planned.map(\.keyData) == ["ed-body", "rsa-body"])
    }

    // MARK: - candidates(from:)

    @Test("candidates(from:) classifies keys, encodes them as OpenSSH, and assigns indices")
    func candidatesFromKeys() throws {
        let rsa = try AsymmetricCryptography.RSA.generateKeyPair(bits: AsymmetricCryptography.RSA.minimumBits)
            .privateKey
        let ed = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair().privateKey

        let candidates = PrivateKeyAuthPlanner.candidates(from: [rsa, ed])
        #expect(candidates.map(\.algorithm) == [.rsa, .ed25519])
        #expect(candidates.map(\.originalIndex) == [0, 1])
        #expect(try candidates.map { try PrivateKey(string: $0.keyData) } == [rsa, ed])
        #expect(candidates.allSatisfy { $0.keyData.contains(OpenSSHKeyCodec.privateKeyHeader) })
    }

    @Test("candidates(from:) leaves out keys SSH cannot use but keeps the original indices")
    func candidatesSkipNonSSHKeys() throws {
        let ed448 = try AsymmetricCryptography.EdDSA.Ed448.generateKeyPair().privateKey
        let p256 = try AsymmetricCryptography.ECDSA.P256.generateKeyPair().privateKey

        let candidates = PrivateKeyAuthPlanner.candidates(from: [ed448, p256])
        #expect(candidates.map(\.algorithm) == [.ecdsaP256])
        #expect(candidates.map(\.originalIndex) == [1])
    }

    @Test("full pipeline: candidates then plan with server preference")
    func candidatesThenPlanPipeline() throws {
        let rsaPath = "\(TS.keyPairsRoot)/rsa-private-openssh-clear"
        let edPath = "\(TS.keyPairsRoot)/ed25519-private-openssh-clear"
        let p256Path = "\(TS.keyPairsRoot)/p256-private-openssh-clear"
        guard FileManager.default.fileExists(atPath: rsaPath),
              FileManager.default.fileExists(atPath: edPath),
              FileManager.default.fileExists(atPath: p256Path) else { return }

        let keys = try [rsaPath, edPath, p256Path].map { try PrivateKey(file: URL(fileURLWithPath: $0)) }
        let planned = PrivateKeyAuthPlanner.plan(
            candidates: PrivateKeyAuthPlanner.candidates(from: keys),
            serverSigAlgs: ["ecdsa-sha2-nistp256", "ssh-ed25519", "rsa-sha2-512"]
        )
        #expect(planned.map(\.algorithm) == [.ecdsaP256, .ed25519, .rsa])
    }
}
