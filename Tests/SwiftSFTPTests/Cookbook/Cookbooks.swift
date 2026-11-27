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

        // Example to be included in `README.md`
        //
        // A simple quick-start example to "sell" the library to users

        // - Instantiate a SFTP client: this connects and logs in
        
        let myClient = try await SFTPClient("localhost:6922", authentication: "bulbasaur:pass123")

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

        // Optional: a released handle closes itself. Close it when the outcome matters, such as before a rename.
        try await myFileHandle.close()

        // - Upload a file
        let localFile = URL(filePath: "myfile.zip")
        try await myClient.upload(from: localFile, to: "/home/bulbasaur/myfolder/myfile.zip")
            { doneBytes, totalBytes, lastBlockBytes, lastBlockTime in
                // return true/false if you want to continue/terminate the upload

                let progress = ((Double(doneBytes) / Double(totalBytes)) * 100).rounded()
                let speed = (Double(lastBlockBytes) / Double(lastBlockTime)).rounded()

                print("Completed \(progress)% at \(speed)B/s")

                return true
            }
        
        // - Deletes a file or directory with everything in it (less radical methods available)
        try await myClient.delete(path: "myfolder")

        // - Close (optional: a released client closes itself, without waiting for the server)
        try await myClient.close()
        
        #expect(firstBytes?.count == 1024)
    }
}
