import AVKit
import Observation
import SwiftSFTP
import SwiftSFTPAVFoundation

/// Owns the SFTP connections for the lifetime of the player item that streams from them.
@MainActor
@Observable
final class PlayerModel {
    var host = ""
    var port = "22"
    var user = ""
    var password = ""
    var path = ""
    /// How many SSH connections stream the file. Each one reads different stripes of it at the same time.
    var connections = 4
    /// How far ahead of playback to read, in MiB.
    var readAheadMiB = 8

    private(set) var player: AVPlayer?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private var clients: [SFTPClient] = []
    private var statusObservation: NSKeyValueObservation?
    private var generation = 0

    var isPlaying: Bool {
        player != nil
    }

    var canPlay: Bool {
        !isLoading && !host.isEmpty && !user.isEmpty && !password.isEmpty && !path.isEmpty
            && Int(port).map { (1 ... 65535).contains($0) } == true
    }

    func play() async {
        guard canPlay else { return }
        generation += 1
        let attempt = generation
        isLoading = true
        errorMessage = nil
        defer {
            if generation == attempt {
                isLoading = false
            }
        }

        await closePlayback()
        guard generation == attempt, !Task.isCancelled else { return }

        do {
            let connection = try await SFTPClient.initAndLogin(
                openSocketIn: TCPLocation(hostname: host, port: Int(port) ?? 22),
                // Demonstration only. Use a pinned host key or known_hosts in a production app.
                hostKeyAcceptance: .acceptAny,
                authentication: UserAuthentication(name: user, auth: .password(password))
            )
            // The view may have disappeared while SSH was connecting. Always close that late connection.
            guard generation == attempt, !Task.isCancelled else {
                try? await connection.close()
                return
            }
            clients = [connection]

            // Each fork is another SSH connection with the same settings and credentials.
            let forks = try await Self.fork(connection, count: connections - 1)
            guard generation == attempt, !Task.isCancelled else {
                await Self.close(forks)
                return
            }
            clients += forks

            // AVFoundation requests byte ranges on demand, including when the user seeks. The connections fetch
            // stripes of the file in parallel and read ahead of playback.
            let item = clients.makePlayerItem(at: path, readAheadSize: readAheadMiB * 1024 * 1024)
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let message = item.error?.localizedDescription ?? "The file could not be played."
                Task { @MainActor in
                    guard self?.generation == attempt else { return }
                    self?.errorMessage = message
                }
            }
            let player = AVPlayer(playerItem: item)
            self.player = player
            player.play()
        }
        catch {
            guard generation == attempt else { return }
            errorMessage = error.localizedDescription
            await closePlayback()
        }
    }

    func stop() async {
        generation += 1
        isLoading = false
        await closePlayback()
    }

    private func closePlayback() async {
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil

        let clients = clients
        self.clients = []
        await Self.close(clients)
    }

    /// Opens `count` more connections at once, closing the ones that opened if any of them fails.
    private static func fork(_ client: SFTPClient, count: Int) async throws -> [SFTPClient] {
        let results = await withTaskGroup(of: Result<SFTPClient, any Error>.self) { group in
            for _ in 0 ..< max(count, 0) {
                group.addTask {
                    do {
                        let fork = try await client.fork()
                        return .success(fork)
                    }
                    catch {
                        return .failure(error)
                    }
                }
            }
            var results: [Result<SFTPClient, any Error>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        let forks = results.compactMap { try? $0.get() }
        for case let .failure(error) in results {
            await close(forks)
            throw error
        }
        return forks
    }

    private static func close(_ clients: [SFTPClient]) async {
        await withTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask {
                    try? await client.close()
                }
            }
        }
    }
}
