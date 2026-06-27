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
            size: 0,
            modifiedAtSecs: nil
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
        return lowercased.contains("session closed")
            || lowercased.contains("connection reset")
            || lowercased.contains("broken pipe")
            || lowercased.contains("connection refused")
            || lowercased.contains("eof")
    }

    static func friendlyMessage(for message: String) -> String {
        let lowercased = message.lowercased()

        if lowercased.contains("known hosts") || lowercased.contains("known_hosts") {
            return """
            Unable to load the host key store. Quit the app, back up or remove known_hosts.json, then reconnect.
            """
        }

        if lowercased.contains("host key mismatch") || lowercased.contains("mismatch") {
            return "The server's identity has changed. Disconnect and verify with your server administrator."
        }

        if lowercased.contains("host key rejected") {
            return "Connection aborted because the host key was not approved."
        }

        if lowercased.contains("authentication") || lowercased.contains("auth failed") {
            return "Check the username and password."
        }

        if lowercased.contains("timed out") || lowercased.contains("timeout") {
            return "Check the host, port, and network connection."
        }

        if lowercased.contains("session closed") {
            return "The connection was closed. Reconnect and try again."
        }

        if lowercased.contains("permission denied") {
            return "You do not have write permission on the remote side. Check the remote working directory."
        }

        if lowercased.contains("failed to create directory") {
            return "Unable to create the remote working directory. Check the path and write permissions."
        }

        if lowercased.contains("failed to upload") && lowercased.contains("no such file") {
            return "The remote destination directory does not exist. Open a valid directory in the remote pane and try again."
        }

        if lowercased.contains("not found") {
            return "The file or directory was not found."
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
}
