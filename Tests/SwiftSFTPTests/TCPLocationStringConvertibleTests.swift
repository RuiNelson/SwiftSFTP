@testable import SwiftSFTP
import Testing

@Suite("TCPLocation LosslessStringConvertible")
struct TCPLocationStringConvertibleTests {
    @Test(arguments: [
        ("example.com", "example.com", 22),
        ("example.com:2222", "example.com", 2222),
        ("127.0.0.1:1", "127.0.0.1", 1),
        ("127.0.0.1:65535", "127.0.0.1", 65535),
        ("::1", "::1", 22),
        ("fe80::1%en0", "fe80::1%en0", 22),
        ("[::1]", "::1", 22),
        ("[::1]:2222", "::1", 2222),
        ("[2001:db8::1]:443", "2001:db8::1", 443),
        ("[example.com]:2222", "example.com", 2222),
    ])
    func parsesValidStrings(input: String, hostname: String, port: Int) {
        #expect(TCPLocation(input) == TCPLocation(hostname: hostname, port: port))
    }

    @Test(arguments: [
        "",
        ":",
        ":22",
        "host:",
        "host::22",
        "host:0",
        "host:65536",
        "host:99999",
        "host:-1",
        "host:+22",
        "host:2x",
        "host:٢٢",
        "a b:22",
        " host",
        "host ",
        "host:22 ",
        "[host",
        "[]",
        "[]:22",
        "[::1]:",
        "[::1]x",
        "[::1]:2222:1",
        "fe80::1:2222:zz",
        "-bad-.example.com",
    ])
    func rejectsInvalidStrings(input: String) {
        #expect(TCPLocation(input) == nil)
    }

    @Test(arguments: [
        TCPLocation(hostname: "example.com"),
        TCPLocation(hostname: "example.com", port: 2222),
        TCPLocation(hostname: "127.0.0.1", port: 65535),
        TCPLocation(hostname: "::1"),
        TCPLocation(hostname: "::1", port: 2222),
        TCPLocation(hostname: "2001:db8::1", port: 1),
        TCPLocation(hostname: "fe80::1%en0", port: 22),
    ])
    func roundTrips(location: TCPLocation) {
        #expect(TCPLocation(location.description) == location)
    }

    @Test
    func descriptionOmitsDefaultPort() {
        #expect(TCPLocation(hostname: "example.com").description == "example.com")
        #expect(TCPLocation(hostname: "example.com", port: 2222).description == "example.com:2222")
        #expect(TCPLocation(hostname: "::1", port: 2222).description == "[::1]:2222")
    }
}
