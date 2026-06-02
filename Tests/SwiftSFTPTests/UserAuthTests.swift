@testable import SwiftSFTP
import Testing

@Suite("User Authentication", .serialized)
struct UserAuthTests {
    @Test(.enabled(if: TestServerConsts.integrationTestsEnabled()))
    func passwordAuthentication() throws {
        try TestServerConsts.withAuthenticatedSession { session in
            let methods = try #require(UserAuthList(
                session: session,
                username: TestServerConsts.User.bulbasaur.rawValue
            ))
            #expect(methods.contains("password"))
            try UserAuthPassword(
                session: session,
                username: TestServerConsts.User.bulbasaur.rawValue,
                password: TestServerConsts.userPassword
            )
            #expect(UserAuthAuthenticated(session: session))
        }
    }

    @Test(.enabled(if: TestServerConsts.integrationTestsEnabled()), arguments: TestServerConsts.privateKeyFixtures)
    func publicKeyAuthenticationFromPrivateKeyFile(fixture: TestServerConsts.PrivateKeyFixture) throws {
        try TestServerConsts.withAuthenticatedSession { session in
            let methods = try #require(UserAuthList(session: session, username: fixture.user.rawValue))
            #expect(methods.contains("publickey"))
            try TestServerConsts.authenticate(fixture: fixture, session: session)
            #expect(UserAuthAuthenticated(session: session))
        }
    }
}
