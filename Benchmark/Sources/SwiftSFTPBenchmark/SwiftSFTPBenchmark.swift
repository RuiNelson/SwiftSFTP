import Foundation
private import SwiftSFTP

func runSwiftSFTPBenchmarks(
    _ options: BenchmarkOptions,
    identifier: String
) async throws -> [BenchmarkResult] {
    let client = try await SwiftSFTP.SFTPClient.initAndLogin(
        openSocketIn: TCPLocation(hostname: options.host, port: options.port),
        operationsTimeOut: nil,
        loginTimeOut: 30,
        hostKeyAcceptance: .acceptAny,
        authentication: UserAuthentication(
            name: options.username,
            auth: .password(options.password)
        ),
        trapOnDeInitWithoutClose: true
    )

    do {
        let results = try await [
            swiftUpload(options, identifier: identifier, client: client, multiple: false),
            swiftDownload(options, identifier: identifier, client: client, multiple: false),
            swiftUpload(options, identifier: identifier, client: client, multiple: true),
            swiftDownload(options, identifier: identifier, client: client, multiple: true),
        ]
        try await client.close()
        return results
    }
    catch {
        try? await client.close()
        throw error
    }
}

private func swiftUpload(
    _ options: BenchmarkOptions,
    identifier: String,
    client: SwiftSFTP.SFTPClient,
    multiple: Bool
) async throws -> BenchmarkResult {
    let kind = multiple ? "multi" : "simple"
    let name = multiple
        ? "SwiftSFTP upload (\(options.uploadWorkers) workers)"
        : "SwiftSFTP upload"

    func remotePath(_ attempt: Int) -> String {
        options.remotePath("benchmark-\(identifier)-swift-\(kind)-upload-\(attempt)")
    }

    print(name)
    return try await measure(
        name,
        bytes: options.fileSize
    ) { attempt in
        if multiple {
            try await client.multiUpload(
                from: options.file,
                to: remotePath(attempt),
                workers: options.uploadWorkers
            ) { _, _, _, _ in true }
        }
        else {
            try await client.upload(from: options.file, to: remotePath(attempt)) { _, _, _, _ in true }
        }
    } validate: { attempt in
        let actual = try await client.stat(
            path: remotePath(attempt),
            followLink: true
        )?.attributes.fileSize
        guard actual == options.fileSize else {
            throw BenchmarkError.invalidRemoteSize(expected: options.fileSize, actual: actual)
        }
    } cleanup: { attempt in
        try? await client.deleteFile(path: remotePath(attempt))
    }
}

private func swiftDownload(
    _ options: BenchmarkOptions,
    identifier: String,
    client: SwiftSFTP.SFTPClient,
    multiple: Bool
) async throws -> BenchmarkResult {
    let kind = multiple ? "multi" : "simple"
    let name = multiple
        ? "SwiftSFTP download (\(options.downloadWorkers) workers)"
        : "SwiftSFTP download"
    let remotePath = options.remotePath("benchmark-\(identifier)-swift-\(kind)-download")

    func localPath(_ attempt: Int) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("benchmark-\(identifier)-swift-\(kind)-\(attempt)")
    }

    do {
        try await client.upload(from: options.file, to: remotePath) { _, _, _, _ in true }
        print(name)
        let result = try await measure(
            name,
            bytes: options.fileSize
        ) { attempt in
            if multiple {
                try await client.multiDownload(
                    from: remotePath,
                    to: localPath(attempt),
                    workers: options.downloadWorkers
                ) { _, _, _, _ in true }
            }
            else {
                try await client.download(from: remotePath, to: localPath(attempt)) { _, _, _, _ in true }
            }
        } validate: { attempt in
            let actual = try localFileSize(localPath(attempt))
            guard actual == options.fileSize else {
                throw BenchmarkError.invalidDownloadedSize(expected: options.fileSize, actual: actual)
            }
        } cleanup: { attempt in
            try? FileManager.default.removeItem(at: localPath(attempt))
        }
        try await client.deleteFile(path: remotePath)
        return result
    }
    catch {
        try? await client.deleteFile(path: remotePath)
        throw error
    }
}
