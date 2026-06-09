@testable import SwiftSFTP
import Testing

@Suite("Hostkey Validation", .serialized)
struct HostkeyValidationTests {
    // MARK: - Full known_hosts lines

    @Test("RSA full known_hosts line")
    func rsaFullLine() {
        #expect(HostkeyValidationTestData.RSA.fullLine.isValid_HostKey)
        #expect(!HostkeyValidationTestData.RSA.fullLine.isValid_ShortHandHostKey)
    }

    @Test("P-256 full known_hosts line")
    func p256FullLine() {
        #expect(HostkeyValidationTestData.P256.fullLine.isValid_HostKey)
        #expect(!HostkeyValidationTestData.P256.fullLine.isValid_ShortHandHostKey)
    }

    @Test("P-384 full known_hosts line")
    func p384FullLine() {
        #expect(HostkeyValidationTestData.P384.fullLine.isValid_HostKey)
        #expect(!HostkeyValidationTestData.P384.fullLine.isValid_ShortHandHostKey)
    }

    @Test("P-521 full known_hosts line")
    func p521FullLine() {
        #expect(HostkeyValidationTestData.P521.fullLine.isValid_HostKey)
        #expect(!HostkeyValidationTestData.P521.fullLine.isValid_ShortHandHostKey)
    }

    @Test("Ed25519 full known_hosts line")
    func ed25519FullLine() {
        #expect(HostkeyValidationTestData.Ed25519.fullLine.isValid_HostKey)
        #expect(!HostkeyValidationTestData.Ed25519.fullLine.isValid_ShortHandHostKey)
    }

    // MARK: - Shorthand (algorithm base64)

    @Test("RSA shorthand host key")
    func rsaShorthand() {
        #expect(HostkeyValidationTestData.RSA.shorthand.isValid_ShortHandHostKey)
        #expect(!HostkeyValidationTestData.RSA.shorthand.isValid_HostKey)
    }

    @Test("P-256 shorthand host key")
    func p256Shorthand() {
        #expect(HostkeyValidationTestData.P256.shorthand.isValid_ShortHandHostKey)
        #expect(!HostkeyValidationTestData.P256.shorthand.isValid_HostKey)
    }

    @Test("P-384 shorthand host key")
    func p384Shorthand() {
        #expect(HostkeyValidationTestData.P384.shorthand.isValid_ShortHandHostKey)
        #expect(!HostkeyValidationTestData.P384.shorthand.isValid_HostKey)
    }

    @Test("P-521 shorthand host key")
    func p521Shorthand() {
        #expect(HostkeyValidationTestData.P521.shorthand.isValid_ShortHandHostKey)
        #expect(!HostkeyValidationTestData.P521.shorthand.isValid_HostKey)
    }

    @Test("Ed25519 shorthand host key")
    func ed25519Shorthand() {
        #expect(HostkeyValidationTestData.Ed25519.shorthand.isValid_ShortHandHostKey)
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
        #expect(!garbage.isValid_ShortHandHostKey)

        let empty = ""
        #expect(!empty.isValid_HostKey)
        #expect(!empty.isValid_ShortHandHostKey)
    }

    @Test("malformed base64 is rejected")
    func malformedBase64() {
        let line = "127.0.0.1 ssh-ed25519 not-valid-base64!!!"
        #expect(!line.isValid_HostKey)

        let shorthand = "ssh-ed25519 not-valid-base64!!!"
        #expect(!shorthand.isValid_ShortHandHostKey)
    }

    @Test("unknown algorithm is rejected")
    func unknownAlgorithm() {
        let line = "127.0.0.1 ssh-foo AAAAC3NzaC1lZDI1NTE5AAAAIBQS8HuiXtRnfeKTpK+i1Gp7v2ekZBhsicnF95Bp3Zgq"
        #expect(!line.isValid_HostKey)

        let shorthand = "ssh-foo AAAAC3NzaC1lZDI1NTE5AAAAIBQS8HuiXtRnfeKTpK+i1Gp7v2ekZBhsicnF95Bp3Zgq"
        #expect(!shorthand.isValid_ShortHandHostKey)
    }

    @Test("invalid host field is rejected")
    func invalidHostField() {
        let line =
            "not a valid host ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBQS8HuiXtRnfeKTpK+i1Gp7v2ekZBhsicnF95Bp3Zgq"
        #expect(!line.isValid_HostKey)
    }
}
