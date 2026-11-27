@testable import SwiftSFTP
import Testing

@Suite("UserAuthentication string literal")
struct UserAuthenticationLiteralTests {
    @Test
    func usernameAndPassword() {
        let credentials: UserAuthentication = "bulbasaur:pass123"

        #expect(credentials == UserAuthentication(name: "bulbasaur", auth: .password("pass123")))
    }

    @Test
    func passwordMayContainColons() {
        let credentials: UserAuthentication = "bob:a:b:c"

        #expect(credentials == UserAuthentication(name: "bob", auth: .password("a:b:c")))
    }

    @Test
    func emptyPasswordAfterColon() {
        let credentials: UserAuthentication = "bob:"

        #expect(credentials == UserAuthentication(name: "bob", auth: .password("")))
    }

    @Test(arguments: ["bob", "", ":", ":secret"])
    func malformedLiteralDoesNotCrash(text: String) {
        let credentials = UserAuthentication(stringLiteral: text)

        #expect(credentials.name == String(text.prefix { $0 != ":" }))
        switch credentials.auth {
        case .password:
            break
        default:
            Issue.record("expected password authentication")
        }
    }

    @Test
    func usernameOnlyIsRejectedAsInvalidConfiguration() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try SFTPClient.preflightConfigurationCheck("localhost", authentication: "bob")
        }
    }
}
