#if canImport(AVFoundation) && !os(watchOS)
    @testable import SwiftSFTP
    @testable import SwiftSFTPAVFoundation
    import AVFoundation
    import Foundation
    import Testing
    import UniformTypeIdentifiers

    struct AVFoundationUnitTests {
        @Test("constructing assets is lazy and infers only registered content types")
        @MainActor
        func lazyAssetsAndContentTypes() async throws {
            guard #available(macOS 11, iOS 14, tvOS 14, macCatalyst 14, visionOS 1, *) else { return }
            let client = try makeUnconnectedClient()
            let fork = try makeUnconnectedClient()
            // No login: creating any of the conveniences must neither open a file nor connect to the server.
            let protocolClient: any SFTPClientProtocol = client
            let cases: [(String, UTType)] = [
                ("Videos/holiday.MP4", .mpeg4Movie),
                ("Videos/holiday.mov", .quickTimeMovie),
                ("Videos/holiday", .movie),
                ("Videos/holiday.mp4.part", .movie),
            ]
            for (path, expected) in cases {
                let asset = try #require(protocolClient.makeAsset(at: path) as? SFTPMediaAsset)
                #expect(asset.loader.contentType == expected)
                #expect(asset.loader.servingRequestCount == 0)
                #expect(await asset.loader.source.workerCount == 1)
                let striped = try #require([client, fork].makeAsset(at: path) as? SFTPMediaAsset)
                #expect(striped.loader.contentType == expected)
                #expect(await striped.loader.source.workerCount == 2)
            }
            let explicit = try #require(client.makeAsset(at: "movie", contentType: .mpeg4Movie) as? SFTPMediaAsset)
            #expect(explicit.loader.contentType == .mpeg4Movie)
            let item = client.makePlayerItem(at: "movie", contentType: .mpeg4Movie)
            #expect(try #require(item.asset as? SFTPMediaAsset).loader.contentType == .mpeg4Movie)
            let stripedItem = [client, fork].makePlayerItem(at: "movie", contentType: .mpeg4Movie)
            let stripedLoader = try #require(stripedItem.asset as? SFTPMediaAsset).loader
            #expect(stripedLoader.contentType == .mpeg4Movie)
            #expect(await stripedLoader.source.workerCount == 2)
            try await client.close()
            try await fork.close()
        }

        #if os(macOS)
            @Test("an empty client collection fails its precondition")
            func emptyClientCollection() async {
                await #expect(processExitsWith: .failure) {
                    _ = [SFTPClient]().makeAsset(at: "movie.mp4")
                }
            }

            @Test("a client passed twice fails the precondition")
            func repeatedClient() async {
                await #expect(processExitsWith: .failure) {
                    let client = try makeUnconnectedClient()
                    _ = [client, client].makePlayerItem(at: "movie.mp4")
                }
            }
        #endif

        @Test("custom URLs preserve unusual filenames and are unique per asset")
        func customURLs() {
            guard #available(macOS 11, iOS 14, tvOS 14, macCatalyst 14, visionOS 1, *) else { return }
            let name = "férias #1? 100%.mp4"
            let url = SFTPMediaAsset.makeURL(fileName: name)
            #expect(url.scheme == "swiftsftp-media")
            #expect(url.lastPathComponent == name)
            #expect(url.query == nil)
            #expect(url.fragment == nil)
            #expect(url.user == nil)
            #expect(url.password == nil)
            #expect(url != SFTPMediaAsset.makeURL(fileName: name))
            #expect(SFTPMediaAsset.makeURL(fileName: "").lastPathComponent == "media")
        }

        @Test("loading failures carry meaningful POSIX codes")
        func loadingErrors() {
            let cases: [(any Error, Int32)] = [
                (AlreadyClosed(), ENOTCONN),
                (NotLoggedIn(), ENOTCONN),
                (FileTransferErrors.remoteFileNotFound(path: "missing"), ENOENT),
                (FileTransferErrors.remotePathIsADirectory(path: "directory"), EISDIR),
                (LibSSH2Error.sftp(status: .noSuchFile), ENOENT),
                (LibSSH2Error.sftp(status: .permissionDenied), EACCES),
                (LibSSH2Error.socketTimeout(nil), ETIMEDOUT),
                (LibSSH2Error.sftp(status: .connectionLost), ECONNRESET),
                (LibSSH2Error.sftp(status: .failure), EIO),
            ]
            for (error, code) in cases {
                let failure = MediaLoadingError.make(error)
                #expect(failure.domain == NSPOSIXErrorDomain)
                #expect(failure.code == Int(code))
                #expect(failure.userInfo[NSUnderlyingErrorKey] == nil)
            }
            let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EOVERFLOW))
            #expect(MediaLoadingError.make(posix) === posix)
        }
    }

    /// A client that is never logged in. Creating assets with it must not touch the network.
    private func makeUnconnectedClient() throws -> SFTPClient {
        try SFTPClient(
            openSocketIn: TCPLocation(hostname: "localhost", port: 1),
            authentication: UserAuthentication(name: "unused", auth: .password("unused"))
        )
    }
#endif
