@testable import SwiftSFTP
import Foundation
import Testing

@Suite("README Cookbook", .serialized)
struct Cookbook {
    func prepareForReadme() throws {
        let localFile = URL(filePath: "myfile.zip")
        try Data("SwiftSFTP README cookbook example".utf8).write(to: localFile)
    }

    @Test("README.md Example")
    func readme() async throws {
        do {
            try prepareForReadme()
        }
        catch {
            Issue.record("Could not prepare README example files: \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: URL(filePath: "myfile.zip")) }

        //
        // Example to be included in `README.md`
        //
        // A simple quick-start example to "sell" the library to users
        //

        // - Instantiate a SFTP client
        
        let myClient = try SFTPClient(
            openSocketIn: .init(hostname: "localhost", port: 6922),
            hostKeyAcceptance: .acceptAny, // configurable
            authentication: .init(name: "bulbasaur", auth: .password("pass123")) // also OpenSSL supported private keys
        )

        // - Call this to connect
        try await myClient.login()

        // - Check server banner
        let banner = try await myClient.banner
        print(banner)

        // - Home directory
        let home = try await myClient.currentWorkingDirectory
        print(home)

        // - List a directory
        let contents = try await myClient.listDirectory(path: "./Fixtures")

        // - Open a file handle
        let largestFile = contents.bySize.last!
        let myFileHandle = try await myClient.openFile([.read], path: largestFile.fullPath)

        let firstBytes = try await myFileHandle.read(upTo: 1024)
        myFileHandle.offset = 2048
        // ...
        try await myFileHandle.close()

        // - Upload a file
        let localFile = URL(filePath: "myfile.zip")
        try await myClient.upload(from: localFile, to: "myfolder/myfile.zip")
            { doneBytes, totalBytes, lastBlockBytes, lastBlockTime in
                // return true/false if you want to continue/terminate the upload

                let progress = ((Double(doneBytes) / Double(totalBytes)) * 100).rounded()
                let speed = (Double(lastBlockBytes) / Double(lastBlockTime)).rounded()

                print("Completed \(progress)% at \(speed)B/s")

                return true
            }
        
        // - Deletes the directory with everything in it, less dangerous methods available
        try await myClient.delete(path: "myfolder")

        // - Close
        try await myClient.close()
        
        #expect(firstBytes?.count == 1024)
    }
}
