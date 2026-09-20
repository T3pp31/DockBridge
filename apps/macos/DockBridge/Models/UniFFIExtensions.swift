import Foundation

extension RemoteFileRecord: Identifiable {
    public var id: String { path }

    var isParentDirectory: Bool { name == ".." }

    var modificationDate: Date? {
        guard let modifiedAtSecs else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(modifiedAtSecs))
    }

    var modificationSortKey: Date { modificationDate ?? .distantPast }

    static func parentEntry(for path: String) -> RemoteFileRecord? {
        guard path != "/", let parent = try? RemotePath.parent(of: path) else { return nil }
        return RemoteFileRecord(
            name: "..",
            path: parent,
            isDirectory: true,
            isSymlink: false,
            size: 0,
            modifiedAtSecs: nil,
            permissions: nil,
            uid: nil,
            gid: nil,
            symlinkTarget: nil,
            symlinkTargetIsDir: nil
        )
    }
}

extension TransferTaskRecord: Identifiable {}

extension DockBridgeError {
    var userFriendlyMessage: String {
        switch self {
        case .Generic(let message):
            return Self.friendlyMessage(for: message)
        }
    }

    static func isConnectionLostMessage(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        if lowercased.contains("session closed")
            || lowercased.contains("connection reset")
            || lowercased.contains("broken pipe")
            || lowercased.contains("connection refused")
            || lowercased.contains("sender dropped")
            || lowercased.contains("channel closed")
            || lowercased.contains("recv error") {
            return true
        }
        // "eof" only as its own token (not inside user-controlled path segments)
        // so geoffrey / thereof.txt do not tear down a live session.
        let tokens = lowercased.split {
            !$0.isLetter && !$0.isNumber && $0 != "_"
        }
        return tokens.contains(where: { $0 == "eof" || $0 == "eof," })
    }

    /// Detects SSH authentication / private-key unlock failures from raw bridge messages.
    /// Prefer matching the underlying Generic message before friendly mapping.
    static func isAuthenticationMessage(_ message: String) -> Bool {
        let lowercased = message.lowercased()

        // Method unavailable is not recoverable via an interactive credential prompt.
        if lowercased.contains("password authentication is not supported") {
            return false
        }

        // Known friendly mapping produced by `friendlyMessage(for:)`.
        if lowercased.contains("check the username and password") {
            return true
        }

        return lowercased.contains("authentication failed")
            || lowercased.contains("auth failed")
            || lowercased.contains("failed to load private key")
            || lowercased.contains("incorrect passphrase")
    }

    static func friendlyMessage(for message: String) -> String {
        let lowercased = message.lowercased()

        if lowercased.contains("known hosts") || lowercased.contains("known_hosts") {
            return String(localized: "Unable to load the host key store. Quit the app, back up or remove known_hosts.json, then reconnect.")
        }

        if lowercased.contains("host key mismatch") || lowercased.contains("mismatch") {
            return String(localized: "The server's identity has changed. Disconnect and verify with your server administrator.")
        }

        if lowercased.contains("host key rejected") {
            return String(localized: "Connection aborted because the host key was not approved.")
        }

        if lowercased.contains("authentication") || lowercased.contains("auth failed") {
            return String(localized: "Check the username and password.")
        }

        if lowercased.contains("timed out") || lowercased.contains("timeout") {
            return String(localized: "Check the host, port, and network connection.")
        }

        if lowercased.contains("session closed") {
            return String(localized: "The connection was closed. Reconnect and try again.")
        }

        if lowercased.contains("permission denied") {
            return String(localized: "You do not have write permission on the remote side. Check the remote working directory.")
        }

        if lowercased.contains("failed to create directory") {
            return String(localized: "Unable to create the remote working directory. Check the path and write permissions.")
        }

        if lowercased.contains("failed to upload") && lowercased.contains("no such file") {
            return String(localized: "The remote destination directory does not exist. Open a valid directory in the remote pane and try again.")
        }

        if lowercased.contains("not found") {
            return String(localized: "The file or directory was not found.")
        }

        return message
    }
}

extension Error {
    var dockBridgeUserMessage: String {
        if let error = self as? DockBridgeError {
            return error.userFriendlyMessage
        }
        return localizedDescription
    }

    var isConnectionLost: Bool {
        if let error = self as? DockBridgeError, case .Generic(let message) = error {
            return DockBridgeError.isConnectionLostMessage(message)
        }
        return false
    }

    /// True when the error represents an authentication / key-passphrase failure.
    /// Inspects the raw `DockBridgeError.Generic` message when available.
    var isAuthenticationFailure: Bool {
        if let error = self as? DockBridgeError, case .Generic(let message) = error {
            return DockBridgeError.isAuthenticationMessage(message)
        }
        if DockBridgeError.isAuthenticationMessage(localizedDescription) {
            return true
        }
        return DockBridgeError.isAuthenticationMessage(dockBridgeUserMessage)
    }
}
