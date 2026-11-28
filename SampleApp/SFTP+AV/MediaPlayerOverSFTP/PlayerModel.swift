import AVKit
import Observation
import SwiftSFTP
import SwiftSFTPAVFoundation

/// Owns the swarm of SFTP connections for the lifetime of the player item that streams from it.
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

    private var swarm: SFTPSwarm?
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
            let connection = try await SFTPClient(
                TCPLocation(hostname: host, port: Int(port) ?? 22),
                // Demonstration only. Use a pinned host key or known_hosts in a production app.
                hostKeyAcceptance: .acceptAny,
                authentication: UserAuthentication(name: user, auth: .password(password))
            )
            // The view may have disappeared while SSH was connecting. Always close that late connection.
            guard generation == attempt, !Task.isCancelled else {
                try? await connection.close()
                return
            }

            // The swarm owns the connection from here and forks the others from it: each fork is another SSH
            // connection with the same settings and credentials. A failed fork leaves the connection to us.
            let swarm: SFTPSwarm
            do {
                swarm = try await SFTPSwarm(connection, numberOfForksToCreate: max(connections - 1, 0))
            }
            catch {
                try? await connection.close()
                throw error
            }
            guard generation == attempt, !Task.isCancelled else {
                try? await swarm.close()
                return
            }
            self.swarm = swarm

            // AVFoundation requests byte ranges on demand, including when the user seeks. The swarm's connections
            // fetch stripes of the file in parallel and read ahead of playback.
            let item = await swarm.makePlayerItem(path: path, readAhead: readAheadMiB * 1024 * 1024)
            // Stopped while the item was being made: playback was already closed.
            guard generation == attempt, !Task.isCancelled else { return }
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

        let swarm = swarm
        self.swarm = nil
        try? await swarm?.close()
    }
}
