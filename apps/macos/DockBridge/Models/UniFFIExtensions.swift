import Foundation

extension RemoteFileRecord: Identifiable {
    public var id: String { path }
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
            ホスト鍵ストアを読み込めません。アプリを終了し、known_hosts.json を退避または削除してから再接続してください。
            """
        }

        if lowercased.contains("host key mismatch") || lowercased.contains("mismatch") {
            return "サーバーの識別情報が前回と異なります。接続を中止し、サーバー管理者に確認してください。"
        }

        if lowercased.contains("host key rejected") || lowercased.contains("rejected") {
            return "ホスト鍵の承認が拒否されたため、接続を中止しました。"
        }

        if lowercased.contains("authentication") || lowercased.contains("auth failed") {
            return "ユーザー名またはパスワードを確認してください。"
        }

        if lowercased.contains("timed out") || lowercased.contains("timeout") {
            return "接続先・ポート・ネットワークを確認してください。"
        }

        if lowercased.contains("session closed") {
            return "接続が切断されました。再接続してから再試行してください。"
        }

        if lowercased.contains("permission denied") {
            return "リモート先への書き込み権限がありません。リモートの作業ディレクトリを確認してください。"
        }

        if lowercased.contains("not found") {
            return "ファイルまたはディレクトリが見つかりません。"
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
