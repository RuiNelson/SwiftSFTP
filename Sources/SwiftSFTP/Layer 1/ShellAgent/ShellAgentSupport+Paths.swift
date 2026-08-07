import PathWorks

extension ShellAgentSupport {
    /// Normalizes a user path and rewrites it into the form the remote shell expects.
    ///
    /// On Unix shells, paths stay SFTP/POSIX (`/` separators). On Windows shells, SFTP drive form (`/C:/...`) and mixed
    /// Windows input are rewritten to native paths (`C:\...`) so `exec`'d tools see OS paths.
    static func pathForRemoteShell(_ path: String, shellType: ShellType) -> String {
        switch shellType {
        case .zshDarwin, .bashLinux, .otherUnixLike:
            // Accept accidental backslashes; never invent drive-letter SFTP forms on Unix hosts.
            path
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "/")
                .sanitizePath

        case .windowsCommandPrompt, .windowsPowerShell:
            // Any Windows or SFTP spelling → canonical SFTP → native Windows for the shell.
            path.sftpPathFromWindows.windowsPathFromSFTP
        }
    }

    /// SFTP-style path used only for parent-directory computation with PathWorks (`/` separators).
    static func sftpFormForParentComputation(_ path: String, shellType: ShellType) -> String {
        switch shellType {
        case .zshDarwin, .bashLinux, .otherUnixLike:
            pathForRemoteShell(path, shellType: shellType)
        case .windowsCommandPrompt, .windowsPowerShell:
            path.sftpPathFromWindows
        }
    }
}

extension String {
    /// PathWorks drive roots (`/C:`) and the conventional OpenSSH form (`/C:/`).
    var isSFTPDriveRootOrSlash: Bool {
        if count == 3 {
            var index = startIndex
            guard self[index] == "/" else { return false }
            index = self.index(after: index)
            guard self[index].isLetter else { return false }
            index = self.index(after: index)
            return self[index] == ":"
        }
        if count == 4 {
            var index = startIndex
            guard self[index] == "/" else { return false }
            index = self.index(after: index)
            guard self[index].isLetter else { return false }
            index = self.index(after: index)
            guard self[index] == ":" else { return false }
            index = self.index(after: index)
            return self[index] == "/"
        }
        return false
    }
}
