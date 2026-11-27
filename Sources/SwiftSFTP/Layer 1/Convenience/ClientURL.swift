import Foundation

public extension SFTPClientProtocol {
    /// Connects and logs in with password credentials written as a URL, such as `sftp://alice:secret@example.com:2222`.
    ///
    /// The port defaults to 22. The user name and the password are percent-decoded, so a reserved character in them is
    /// written as `%XX`. A URL has no place for a private key: use ``init(_:hostKeyAcceptance:authentication:compressionPreference:loginTimeOut:operationsTimeOut:deinitErrorHandler:)``
    /// for key authentication.
    ///
    /// - Parameters:
    ///   - url: An `sftp://user:password@host[:port]` URL without a path.
    ///   - hostKeyAcceptance: Host-key policy.
    ///   - compressionPreference: Compression algorithms to offer, in order of preference, for each direction.
    ///   - loginTimeOut: Positive timeout for the connection, handshake, authentication, and SFTP initialization.
    ///   - operationsTimeOut: Positive timeout for ordinary blocking operations, or `nil` for none.
    ///   - deinitErrorHandler: Receives the failures of closing what the client owns when it is released without
    /// `close()`.
    /// - Throws: ``SFTPURLError`` when the URL is not an SFTP URL with a host, a user name and a password, and the
    /// errors of the initializer that takes a ``TCPLocation``.
    init(
        _ url: URL,
        hostKeyAcceptance: HostKeyAcceptance = .acceptAny,
        compressionPreference:
        (clientToServer: [CompressionAlgorithm], serverToClient: [CompressionAlgorithm]) = ([], []),
        loginTimeOut: TimeInterval = 10.0,
        operationsTimeOut: TimeInterval? = 10.0,
        deinitErrorHandler: @escaping DeinitErrorHandler = debugPrintDeinitErrorHandler
    ) async throws {
        // URLComponents percent-decodes `host`, `user` and `password`, and works before macOS 13.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SFTPURLError.couldNotBeParsed
        }

        guard components.scheme?.lowercased() == "sftp" else {
            throw SFTPURLError.invalidScheme
        }

        guard components.path.isEmpty || components.path == "/" else {
            throw SFTPURLError.hasPath
        }

        guard let host = components.host, !host.isEmpty else {
            throw SFTPURLError.missingMandatoryPart("host")
        }

        guard let user = components.user, !user.isEmpty else {
            throw SFTPURLError.missingMandatoryPart("user")
        }

        guard let password = components.password else {
            throw SFTPURLError.missingMandatoryPart("password")
        }

        try await self.init(
            TCPLocation(hostname: host, port: components.port ?? 22),
            hostKeyAcceptance: hostKeyAcceptance,
            authentication: UserAuthentication(name: user, auth: .password(password)),
            compressionPreference: compressionPreference,
            loginTimeOut: loginTimeOut,
            operationsTimeOut: operationsTimeOut,
            deinitErrorHandler: deinitErrorHandler
        )
    }

    /// Connects and logs in with password credentials written as a URL string, such as
    /// `"sftp://alice:secret@example.com:2222"`.
    ///
    /// See ``init(_:hostKeyAcceptance:compressionPreference:loginTimeOut:operationsTimeOut:deinitErrorHandler:)`` for
    /// the URL form and the parameters.
    ///
    /// - Throws: ``SFTPURLError/couldNotBeParsed`` when `url` is not a valid URL, and the errors of the initializer
    /// that takes a `URL`.
    init(
        _ url: String,
        hostKeyAcceptance: HostKeyAcceptance = .acceptAny,
        compressionPreference:
        (clientToServer: [CompressionAlgorithm], serverToClient: [CompressionAlgorithm]) = ([], []),
        loginTimeOut: TimeInterval = 10.0,
        operationsTimeOut: TimeInterval? = 10.0,
        deinitErrorHandler: @escaping DeinitErrorHandler = debugPrintDeinitErrorHandler
    ) async throws {
        guard let url = URL(string: url) else {
            throw SFTPURLError.couldNotBeParsed
        }

        try await self.init(
            url,
            hostKeyAcceptance: hostKeyAcceptance,
            compressionPreference: compressionPreference,
            loginTimeOut: loginTimeOut,
            operationsTimeOut: operationsTimeOut,
            deinitErrorHandler: deinitErrorHandler
        )
    }
}
