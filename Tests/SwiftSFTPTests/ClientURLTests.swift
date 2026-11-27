@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SFTPClient from a URL")
struct ClientURLTests {
    private func urlError(_ text: String) async -> SFTPURLError? {
        do {
            _ = try await SFTPClient(text, loginTimeOut: 2)
            return nil
        }
        catch {
            return error as? SFTPURLError
        }
    }

    @Test
    func rejectsOtherSchemes() async {
        #expect(await urlError("http://bob:pw@localhost") == .invalidScheme)
        #expect(await urlError("bob:pw@localhost") == .invalidScheme)
    }

    @Test
    func rejectsAPath() async {
        #expect(await urlError("sftp://bob:pw@localhost/home/bob") == .hasPath)
    }

    @Test
    func rejectsMissingParts() async {
        #expect(await urlError("sftp://bob:pw@") == .missingMandatoryPart("host"))
        #expect(await urlError("sftp://localhost") == .missingMandatoryPart("user"))
        #expect(await urlError("sftp://bob@localhost") == .missingMandatoryPart("password"))
    }

    @Test
    func rejectsTextThatIsNotAURL() async {
        #expect(await urlError("sftp://bob:pw@local host") == .couldNotBeParsed)
    }

    @Test(arguments: [
        "sftp://bob:pw@127.0.0.1:1",
        "sftp://bob:p%40ss%3Aword@127.0.0.1:1/",
        "SFTP://bob:pw@[::1]:1",
    ])
    func wellFormedURLsGetPastParsing(text: String) async {
        // Nothing listens on port 1: the error is the connection's, not the URL's.
        #expect(await urlError(text) == nil)
    }
}
