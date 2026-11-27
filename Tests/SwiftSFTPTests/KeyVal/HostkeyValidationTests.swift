@testable import SwiftSFTP
import Testing

@Suite("Hostkey Validation", .serialized)
struct HostkeyValidationTests {
    // MARK: - Full known_hosts lines

    @Test("RSA full known_hosts line")
    func rsaFullLine() {
        #expect(HostkeyValidationTestData.RSA.fullLine.isValid_HostKey)
    }

    @Test("P-256 full known_hosts line")
    func p256FullLine() {
        #expect(HostkeyValidationTestData.P256.fullLine.isValid_HostKey)
    }

    @Test("P-384 full known_hosts line")
    func p384FullLine() {
        #expect(HostkeyValidationTestData.P384.fullLine.isValid_HostKey)
    }

    @Test("P-521 full known_hosts line")
    func p521FullLine() {
        #expect(HostkeyValidationTestData.P521.fullLine.isValid_HostKey)
    }

    @Test("Ed25519 full known_hosts line")
    func ed25519FullLine() {
        #expect(HostkeyValidationTestData.Ed25519.fullLine.isValid_HostKey)
    }

    // MARK: - Key without a host (algorithm base64)

    @Test("RSA key without a host is not a known_hosts line")
    func rsaKeyWithoutHost() {
        #expect(!HostkeyValidationTestData.RSA.shorthand.isValid_HostKey)
    }

    @Test("P-256 key without a host is not a known_hosts line")
    func p256KeyWithoutHost() {
        #expect(!HostkeyValidationTestData.P256.shorthand.isValid_HostKey)
    }

    @Test("P-384 key without a host is not a known_hosts line")
    func p384KeyWithoutHost() {
        #expect(!HostkeyValidationTestData.P384.shorthand.isValid_HostKey)
    }

    @Test("P-521 key without a host is not a known_hosts line")
    func p521KeyWithoutHost() {
        #expect(!HostkeyValidationTestData.P521.shorthand.isValid_HostKey)
    }

    @Test("Ed25519 key without a host is not a known_hosts line")
    func ed25519KeyWithoutHost() {
        #expect(!HostkeyValidationTestData.Ed25519.shorthand.isValid_HostKey)
    }

    // MARK: - Host field variants

    @Test("[host]:port known_hosts line")
    func portLine() {
        #expect(HostkeyValidationTestData.Ed25519.portLine.isValid_HostKey)
    }

    @Test("hashed host known_hosts line")
    func hashedLine() {
        #expect(HostkeyValidationTestData.hashedLine.isValid_HostKey)
    }

    @Test("known_hosts line with comment")
    func lineWithComment() {
        #expect(HostkeyValidationTestData.RSA.lineWithComment.isValid_HostKey)
    }

    // MARK: - Invalid inputs

    @Test("invalid strings are rejected")
    func invalidStrings() {
        let garbage = "not a host key at all"
        #expect(!garbage.isValid_HostKey)

        let empty = ""
        #expect(!empty.isValid_HostKey)
    }

    @Test("malformed base64 is rejected")
    func malformedBase64() {
        let line = "127.0.0.1 ssh-ed25519 not-valid-base64!!!"
        #expect(!line.isValid_HostKey)
    }

    @Test("unknown algorithm is rejected")
    func unknownAlgorithm() {
        let line = "127.0.0.1 ssh-foo AAAAC3NzaC1lZDI1NTE5AAAAIBQS8HuiXtRnfeKTpK+i1Gp7v2ekZBhsicnF95Bp3Zgq"
        #expect(!line.isValid_HostKey)
    }

    @Test("invalid host field is rejected")
    func invalidHostField() {
        let line =
            "not a valid host ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBQS8HuiXtRnfeKTpK+i1Gp7v2ekZBhsicnF95Bp3Zgq"
        #expect(!line.isValid_HostKey)
    }
}
