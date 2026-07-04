@testable import SwiftSFTP
import Testing

@Suite("TCPLocation known_hosts host field")
struct TCPLocationKnownHostsTests {
    // MARK: - Valid host fields

    @Test("accepts plain IPv4")
    func plainIPv4() {
        #expect(TCPLocation.isValidKnownHostsHostField("127.0.0.1"))
        #expect(TCPLocation.isValidKnownHostsHostField(HostkeyValidationTestData.testHost))
    }

    @Test("accepts IPv4 with port")
    func ipv4WithPort() {
        #expect(TCPLocation.isValidKnownHostsHostField("127.0.0.1:2222"))
        #expect(TCPLocation.isValidKnownHostsHostField("10.0.0.1:1"))
        #expect(TCPLocation.isValidKnownHostsHostField("10.0.0.1:65535"))
    }

    @Test("accepts bracketed hostname")
    func bracketedHostname() {
        #expect(TCPLocation.isValidKnownHostsHostField("[example.com]"))
        #expect(TCPLocation.isValidKnownHostsHostField("[my-host.example.com]"))
    }

    @Test("accepts bracketed hostname with port")
    func bracketedHostnameWithPort() {
        #expect(TCPLocation.isValidKnownHostsHostField("[example.com]:2222"))
        #expect(TCPLocation.isValidKnownHostsHostField(HostkeyValidationTestData.portHost))
    }

    @Test("accepts bracketed IPv6")
    func bracketedIPv6() {
        #expect(TCPLocation.isValidKnownHostsHostField("[::1]"))
        #expect(TCPLocation.isValidKnownHostsHostField("[2001:db8::1]:443"))
        #expect(TCPLocation.isValidKnownHostsHostField("[fe80::1%en0]"))
    }

    @Test("accepts plain hostname")
    func plainHostname() {
        #expect(TCPLocation.isValidKnownHostsHostField("example.com"))
        #expect(TCPLocation.isValidKnownHostsHostField("localhost"))
    }

    @Test("accepts hashed host")
    func hashedHost() throws {
        let hashedField = try #require(
            HostkeyValidationTestData.hashedLine
                .split(separator: " ", maxSplits: 1)
                .first
                .map(String.init)
        )
        #expect(TCPLocation.isValidKnownHostsHostField(hashedField))
    }

    @Test("accepts comma-separated hosts")
    func commaSeparatedHosts() {
        #expect(TCPLocation.isValidKnownHostsHostField("127.0.0.1,example.com"))
        #expect(TCPLocation.isValidKnownHostsHostField("[host-a]:22,[host-b]:2222"))
    }

    @Test("knownHostsHost uses OpenSSH format")
    func knownHostsHostFormat() {
        #expect(TCPLocation(hostname: "example.com", port: 22).knownHostsHost == "example.com")
        #expect(TCPLocation(hostname: "example.com", port: 2222).knownHostsHost == "[example.com]:2222")
        #expect(TCPLocation(hostname: "127.0.0.1", port: 22).knownHostsHost == "127.0.0.1")
        #expect(TCPLocation(hostname: "127.0.0.1", port: 2222).knownHostsHost == "[127.0.0.1]:2222")
        #expect(TCPLocation(hostname: "::1", port: 22).knownHostsHost == "::1")
        #expect(TCPLocation(hostname: "::1", port: 2222).knownHostsHost == "[::1]:2222")
    }

    @Test("knownHostsHost produces valid host fields")
    func knownHostsHostRoundTrip() {
        let cases: [TCPLocation] = [
            TCPLocation(hostname: "127.0.0.1", port: 22),
            TCPLocation(hostname: "127.0.0.1", port: 2222),
            TCPLocation(hostname: "example.com", port: 22),
            TCPLocation(hostname: "example.com", port: 2222),
            TCPLocation(hostname: "::1", port: 22),
            TCPLocation(hostname: "2001:db8::1", port: 443),
        ]

        for location in cases {
            #expect(TCPLocation.isValidKnownHostsHostField(location.knownHostsHost))
        }
    }

    // MARK: - Invalid host fields

    @Test("rejects empty and whitespace-only fields")
    func emptyFields() {
        #expect(!TCPLocation.isValidKnownHostsHostField(""))
        #expect(!TCPLocation.isValidKnownHostsHostField("   "))
    }

    @Test("rejects invalid hostnames")
    func invalidHostnames() {
        #expect(!TCPLocation.isValidKnownHostsHostField("-bad.com"))
        #expect(!TCPLocation.isValidKnownHostsHostField(".example.com"))
        #expect(!TCPLocation.isValidKnownHostsHostField("example..com"))
    }

    @Test("rejects invalid ports")
    func invalidPorts() {
        #expect(!TCPLocation.isValidKnownHostsHostField("127.0.0.1:0"))
        #expect(!TCPLocation.isValidKnownHostsHostField("127.0.0.1:65536"))
        #expect(!TCPLocation.isValidKnownHostsHostField("127.0.0.1:not-a-port"))
        #expect(!TCPLocation.isValidKnownHostsHostField("[example.com]:"))
        #expect(!TCPLocation.isValidKnownHostsHostField("[example.com]:abc"))
    }

    @Test("rejects malformed bracket syntax")
    func malformedBrackets() {
        #expect(!TCPLocation.isValidKnownHostsHostField("[unclosed.example.com"))
        #expect(!TCPLocation.isValidKnownHostsHostField("[]"))
    }

    @Test("rejects malformed hashed hosts")
    func malformedHashedHosts() {
        #expect(!TCPLocation.isValidKnownHostsHostField("|1|"))
        #expect(!TCPLocation.isValidKnownHostsHostField("|1|not-base64!|also-not-base64!"))
        #expect(!TCPLocation.isValidKnownHostsHostField("|2|AAAA|BBBB"))
    }

    @Test("rejects comma-separated lists with empty entries")
    func commaSeparatedWithEmptyEntry() {
        #expect(!TCPLocation.isValidKnownHostsHostField("127.0.0.1,,example.com"))
        #expect(!TCPLocation.isValidKnownHostsHostField(","))
    }
}
