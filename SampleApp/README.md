# SFTP media player

Open [SFTP+AV/MediaPlayerOverSFTP.xcodeproj](SFTP+AV/MediaPlayerOverSFTP.xcodeproj) in Xcode and run the
`MediaPlayerOverSFTP` scheme on macOS, iOS, or visionOS (26+). For a physical device, select your signing team.
The project uses this checkout's local Swift package and its `SwiftSFTPAVFoundation` product, which supplies both modules.

If you add the local package again in Xcode, select only `SwiftSFTPAVFoundation`. In the app target's
**Frameworks, Libraries, and Embedded Content**, that product should appear once. Linking the separate `SwiftSFTP`
product as well causes Xcode's duplicate static-library error, even though the source imports both modules.

Enter the SSH host, port (22 by default), username, password, and remote media path, then press **Play**.
Under **Streaming**, choose how many connections stream the file (4 by default) and how far ahead of playback they
read (8 MiB by default); changes apply the next time you press **Play**. The player supports video and audio,
seeking, and restarting playback. The connections stay open during playback and close when the view disappears or
playback is restarted. Credentials are held in memory only.

The sample accepts any SSH host key for demonstration. Configure `hostKeyAcceptance` in `PlayerModel.swift` with
your trusted host key or `known_hosts` content before using it in a production application.

Like SwiftSMB's sample, this app uses a SwiftUI form and `VideoPlayer`. It forks the logged-in client and calls
`makePlayerItem(at:readAheadSize:)` on the array of connections, which then fetch different stripes of the file in
parallel.
