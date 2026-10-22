import AVKit
import Observation
import SwiftSFTP
import SwiftSFTPAVFoundation

/// Owns the SFTP connection for the lifetime of the player item that streams from it.
@MainActor
@Observable
final class PlayerModel {
    var host = ""
    var port = "22"
    var user = ""
    var password = ""
    var path = ""

    private(set) var player: AVPlayer?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private var connection: SFTPClient?
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
            self.connection = connection

            // AVFoundation requests byte ranges on demand, including when the user seeks.
            let item = connection.makePlayerItem(at: path)
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

        let connection = connection
        self.connection = nil
        try? await connection?.close()
    }
}
