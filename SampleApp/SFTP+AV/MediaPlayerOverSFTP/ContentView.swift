import AVKit
import SwiftSFTP
import SwiftSFTPAVFoundation
import SwiftUI

/// Connects to an SFTP server and plays one of its audio or video files with `AVPlayer`.
///
/// The interesting part is `PlayerModel.play()`: once connected, it forks the client into several connections, and
/// `makePlayerItem(at:readAheadSize:)` on that array returns an `AVPlayerItem` that streams the file over all of them.
/// Playback starts without downloading the file first.
struct ContentView: View {
    @State private var model = PlayerModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Host (e.g. nas.local)", text: $model.host)
                    TextField("Port", text: $model.port)
                    TextField("User", text: $model.user)
                    SecureField("Password", text: $model.password)
                }

                Section("File") {
                    TextField("Remote path (e.g. /Videos/trailer.mp4)", text: $model.path)
                }

                Section {
                    Stepper("Connections: \(model.connections)", value: $model.connections, in: 1 ... 8)
                    Stepper("Read-ahead: \(model.readAheadMiB) MiB", value: $model.readAheadMiB, in: 0 ... 64)
                } header: {
                    Text("Streaming")
                } footer: {
                    Text("Changes apply the next time you press Play.")
                }

                Section {
                    Button(model.isPlaying ? "Restart" : "Play") {
                        Task { await model.play() }
                    }
                    .disabled(!model.canPlay)

                    if model.isLoading {
                        ProgressView("Connecting…")
                    }

                    if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                if let player = model.player {
                    Section("Player") {
                        // Audio files play in the same view, which shows only the transport controls.
                        VideoPlayer(player: player)
                            .frame(minHeight: 220)
                    }
                }
            }
            .formStyle(.grouped)
            .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
                .navigationTitle("Play from SFTP")
        }
        .onDisappear {
            Task { await model.stop() }
        }
    }
}

#Preview {
    ContentView()
}
