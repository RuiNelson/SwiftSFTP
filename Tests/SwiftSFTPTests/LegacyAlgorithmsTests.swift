@testable import SwiftSFTP
import Testing

@Suite("Legacy algorithms")
struct LegacyAlgorithmsTests {
    @Test("legacy methods are offered only with the LegacyAlgorithms trait")
    func legacyMethodsFollowTheTrait() throws {
        try SSHInit()
        defer { SSHExit() }

        let session = try SessionInit()
        defer { try? SessionFree(session: session) }

        let legacyMethods: [(LibSSH2SessionMethodType, String)] = [
            (.keyExchange, "diffie-hellman-group1-sha1"),
            (.keyExchange, "diffie-hellman-group14-sha1"),
            (.keyExchange, "diffie-hellman-group-exchange-sha1"),
            (.hostKey, "ssh-rsa"),
            (.hostKey, "ssh-dss"),
            (.macClientToServer, "hmac-sha1"),
            (.macClientToServer, "hmac-md5"),
            (.encryptClientToServer, "3des-cbc"),
        ]
        for (methodType, method) in legacyMethods {
            let offered = try SessionSupportedAlgs(session: session, methodType: methodType).contains(method)
            #if LegacyAlgorithms
                #expect(offered, "\(method) should be offered with the LegacyAlgorithms trait")
            #else
                #expect(!offered, "\(method) should not be offered without the LegacyAlgorithms trait")
            #endif
        }
    }
}
