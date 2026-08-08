@testable import SwiftSFTP
import Foundation
import Testing

@Suite("PrivateKeyAuthPlanner")
struct PrivateKeyAuthPlannerTests {
    private func memory(
        _ text: String,
        passphrase: String? = nil,
        index: Int,
        algorithm: SSHUserKeyAlgorithm?
    ) -> PrivateKeyAuthCandidate {
        PrivateKeyAuthCandidate(
            source: .memory(text),
            passphrase: passphrase,
            algorithm: algorithm,
            originalIndex: index
        )
    }

    private func file(
        _ path: String,
        passphrase: String? = nil,
        index: Int,
        algorithm: SSHUserKeyAlgorithm?
    ) -> PrivateKeyAuthCandidate {
        PrivateKeyAuthCandidate(
            source: .file(URL(fileURLWithPath: path)),
            passphrase: passphrase,
            algorithm: algorithm,
            originalIndex: index
        )
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
        // Only RSA-SHA2; no unclassified keys in this set.
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

    @Test("unclassified keys are kept last when server-sig-algs is present")
    func unclassifiedKeptLastWithServerList() {
        let candidates = [
            memory("unknown", index: 0, algorithm: nil),
            memory("ed", index: 1, algorithm: .ed25519),
        ]
        let server = ["ssh-ed25519", "rsa-sha2-512"]
        let planned = PrivateKeyAuthPlanner.plan(candidates: candidates, serverSigAlgs: server)
        #expect(planned.map(\.algorithm) == [.ed25519, nil])
    }

    @Test("unclassified keys are kept last without server-sig-algs")
    func unclassifiedKeptLastWithoutServerList() {
        let candidates = [
            memory("unknown", index: 0, algorithm: nil),
            memory("rsa", index: 1, algorithm: .rsa),
            memory("ed", index: 2, algorithm: .ed25519),
        ]
        let planned = PrivateKeyAuthPlanner.plan(candidates: candidates, serverSigAlgs: nil)
        #expect(planned.map(\.algorithm) == [.ed25519, .rsa, nil])
    }

    @Test("empty candidate list yields empty plan")
    func emptyCandidates() {
        #expect(PrivateKeyAuthPlanner.plan(candidates: [], serverSigAlgs: nil).isEmpty)
        #expect(
            PrivateKeyAuthPlanner.plan(candidates: [], serverSigAlgs: ["ssh-ed25519"]).isEmpty
        )
    }

    @Test("plan preserves memory vs file source and passphrase")
    func planPreservesSourceMetadata() {
        let candidates = [
            memory("ed-body", passphrase: "secret", index: 0, algorithm: .ed25519),
            file("/tmp/id_rsa", passphrase: nil, index: 1, algorithm: .rsa),
        ]
        let planned = PrivateKeyAuthPlanner.plan(
            candidates: candidates,
            serverSigAlgs: ["ssh-ed25519", "rsa-sha2-512"]
        )
        #expect(planned.count == 2)
        #expect(planned[0].source == .memory("ed-body"))
        #expect(planned[0].passphrase == "secret")
        #expect(planned[1].source == .file(URL(fileURLWithPath: "/tmp/id_rsa")))
        #expect(planned[1].passphrase == nil)
    }

    // MARK: - candidates(from:)

    @Test("candidates(from:) classifies memory keys and assigns indices")
    func candidatesFromMemorySet() throws {
        let rsaPath = "TestServer/KeyPairs/rsa-private-openssh-clear"
        let edPath = "TestServer/KeyPairs/ed25519-private-openssh-clear"
        guard FileManager.default.fileExists(atPath: rsaPath),
              FileManager.default.fileExists(atPath: edPath) else { return }

        let rsa = try String(contentsOfFile: rsaPath, encoding: .utf8)
        let ed = try String(contentsOfFile: edPath, encoding: .utf8)
        let set = PrivateKeySet(strings: [
            PrivateKeyString(representation: rsa),
            PrivateKeyString(representation: ed),
        ])

        let candidates = PrivateKeyAuthPlanner.candidates(from: set)
        #expect(candidates.count == 2)
        #expect(candidates[0].algorithm == .rsa)
        #expect(candidates[0].originalIndex == 0)
        #expect(candidates[0].source == .memory(rsa))
        #expect(candidates[1].algorithm == .ed25519)
        #expect(candidates[1].originalIndex == 1)
    }

    @Test("candidates(from:) classifies file keys after string keys")
    func candidatesFromMixedSet() throws {
        let rsaPath = "TestServer/KeyPairs/rsa-private-openssh-clear"
        let edPath = "TestServer/KeyPairs/ed25519-private-openssh-clear"
        guard FileManager.default.fileExists(atPath: rsaPath),
              FileManager.default.fileExists(atPath: edPath) else { return }

        let rsa = try String(contentsOfFile: rsaPath, encoding: .utf8)
        let set = PrivateKeySet(
            strings: [PrivateKeyString(representation: rsa)],
            files: [PrivateKeyFile(file: URL(fileURLWithPath: edPath))]
        )

        let candidates = PrivateKeyAuthPlanner.candidates(from: set)
        #expect(candidates.count == 2)
        #expect(candidates[0].algorithm == .rsa)
        #expect(candidates[0].originalIndex == 0)
        #expect(candidates[1].algorithm == .ed25519)
        #expect(candidates[1].originalIndex == 1)
        if case let .file(url) = candidates[1].source {
            #expect(url.path == URL(fileURLWithPath: edPath).path)
        }
        else {
            Issue.record("expected file source for second candidate")
        }
    }

    @Test("candidates(from:) marks missing files as unclassified")
    func candidatesMissingFileUnclassified() {
        let missing = URL(fileURLWithPath: "/tmp/swiftSFTP-no-such-key-\(UUID().uuidString)")
        let set = PrivateKeySet(files: [PrivateKeyFile(file: missing)])
        let candidates = PrivateKeyAuthPlanner.candidates(from: set)
        #expect(candidates.count == 1)
        #expect(candidates[0].algorithm == nil)
        #expect(candidates[0].source == .file(missing))
    }

    @Test("candidates(from:) detects encrypted PKCS#8 with passphrase")
    func candidatesEncryptedWithPassphrase() throws {
        let path = "TestServer/KeyPairs/rsa-private-pkcs8-encrypted"
        guard FileManager.default.fileExists(atPath: path) else { return }

        let text = try String(contentsOfFile: path, encoding: .utf8)
        let without = PrivateKeyAuthPlanner.candidates(
            from: PrivateKeySet(strings: [PrivateKeyString(representation: text)])
        )
        let with = PrivateKeyAuthPlanner.candidates(
            from: PrivateKeySet(strings: [
                PrivateKeyString(representation: text, passphrase: TS.keyPassphrase),
            ])
        )
        #expect(with.first?.algorithm == .rsa)
        #expect(with.first?.passphrase == TS.keyPassphrase)
        // Encrypted PKCS#8 without passphrase cannot be classified.
        #expect(without.first?.algorithm == nil)
        #expect(SSHUserKeyAlgorithm.detect(from: text) == nil)
    }

    @Test("full pipeline: candidates then plan with server preference")
    func candidatesThenPlanPipeline() throws {
        let rsaPath = "TestServer/KeyPairs/rsa-private-openssh-clear"
        let edPath = "TestServer/KeyPairs/ed25519-private-openssh-clear"
        let p256Path = "TestServer/KeyPairs/p256-private-openssh-clear"
        guard FileManager.default.fileExists(atPath: rsaPath),
              FileManager.default.fileExists(atPath: edPath),
              FileManager.default.fileExists(atPath: p256Path) else { return }

        let set = PrivateKeySet(files: [
            PrivateKeyFile(file: URL(fileURLWithPath: rsaPath)),
            PrivateKeyFile(file: URL(fileURLWithPath: edPath)),
            PrivateKeyFile(file: URL(fileURLWithPath: p256Path)),
        ])
        let planned = PrivateKeyAuthPlanner.plan(
            candidates: PrivateKeyAuthPlanner.candidates(from: set),
            serverSigAlgs: ["ecdsa-sha2-nistp256", "ssh-ed25519", "rsa-sha2-512"]
        )
        #expect(planned.map(\.algorithm) == [.ecdsaP256, .ed25519, .rsa])
    }
}
