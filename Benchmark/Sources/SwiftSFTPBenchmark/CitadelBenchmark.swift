private import Citadel
import Foundation

private let citadelBufferSize = 512 * 1024

func runCitadelBenchmarks(
    _ options: BenchmarkOptions,
    identifier: String
) async throws -> [BenchmarkResult] {
    let settings = SSHClientSettings(
        host: options.host,
        port: options.port,
        authenticationMethod: {
            .passwordBased(username: options.username, password: options.password)
        },
        hostKeyValidator: .acceptAnything()
    )
    let ssh = try await SSHClient.connect(to: settings)

    do {
        let sftp = try await ssh.openSFTP()
        do {
            let upload = try await citadelUpload(options, identifier: identifier, client: sftp)
            let download = try await citadelDownload(options, identifier: identifier, client: sftp)
            try await sftp.close()
            try await ssh.close()
            return [upload, download]
        }
        catch {
            try? await sftp.close()
            try? await ssh.close()
            throw error
        }
    }
    catch {
        try? await ssh.close()
        throw error
    }
}

private func citadelUpload(
    _ options: BenchmarkOptions,
    identifier: String,
    client: Citadel.SFTPClient
) async throws -> BenchmarkResult {
    func remotePath(_ attempt: Int) -> String {
        options.remotePath("benchmark-\(identifier)-citadel-upload-\(attempt)")
    }

    print("Citadel upload")
    return try await measure(
        "Citadel upload",
        bytes: options.fileSize
    ) { attempt in
        try await citadelUploadFile(options.file, to: remotePath(attempt), client: client)
    } validate: { attempt in
        let actual = try await client.getAttributes(at: remotePath(attempt)).size
        guard actual == options.fileSize else {
            throw BenchmarkError.invalidRemoteSize(expected: options.fileSize, actual: actual)
        }
    } cleanup: { attempt in
        try? await client.remove(at: remotePath(attempt))
    }
}

private func citadelDownload(
    _ options: BenchmarkOptions,
    identifier: String,
    client: Citadel.SFTPClient
) async throws -> BenchmarkResult {
    let remotePath = options.remotePath("benchmark-\(identifier)-citadel-download")

    func localPath(_ attempt: Int) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("benchmark-\(identifier)-citadel-\(attempt)")
    }

    do {
        try await citadelUploadFile(options.file, to: remotePath, client: client)
        print("Citadel download")
        let result = try await measure(
            "Citadel download",
            bytes: options.fileSize
        ) { attempt in
            try await citadelDownloadFile(
                remotePath,
                to: localPath(attempt),
                size: options.fileSize,
                client: client
            )
        } validate: { attempt in
            let actual = try localFileSize(localPath(attempt))
            guard actual == options.fileSize else {
                throw BenchmarkError.invalidDownloadedSize(expected: options.fileSize, actual: actual)
            }
        } cleanup: { attempt in
            try? FileManager.default.removeItem(at: localPath(attempt))
        }
        try await client.remove(at: remotePath)
        return result
    }
    catch {
        try? await client.remove(at: remotePath)
        throw error
    }
}

private func citadelUploadFile(
    _ localURL: URL,
    to remotePath: String,
    client: Citadel.SFTPClient
) async throws {
    try await client.withFile(
        filePath: remotePath,
        flags: [.write, .create, .forceCreate]
    ) { file in
        let source = try FileHandle(forReadingFrom: localURL)
        defer { try? source.close() }

        var offset: UInt64 = 0
        while let data = try source.read(upToCount: citadelBufferSize), !data.isEmpty {
            try await file.write(.init(bytes: data), at: offset)
            offset += UInt64(data.count)
        }
    }
}

private func citadelDownloadFile(
    _ remotePath: String,
    to localURL: URL,
    size: UInt64,
    client: Citadel.SFTPClient
) async throws {
    _ = FileManager.default.createFile(atPath: localURL.path, contents: nil)

    try await client.withFile(filePath: remotePath, flags: .read) { file in
        let destination = try FileHandle(forWritingTo: localURL)
        defer { try? destination.close() }

        var offset: UInt64 = 0
        while offset < size {
            let length = UInt32(min(UInt64(citadelBufferSize), size - offset))
            var buffer = try await file.read(from: offset, length: length)
            let count = buffer.readableBytes
            guard count > 0, let bytes = buffer.readBytes(length: count) else {
                throw BenchmarkError.unexpectedEndOfFile
            }
            try destination.write(contentsOf: Data(bytes))
            offset += UInt64(count)
        }
    }
}
