import Foundation

enum FileDropError: LocalizedError {
    case invalidMove
    case notConnected
    case emptyPayload
    case unreadableSource

    var errorDescription: String? {
        switch self {
        case .invalidMove:
            return String(localized: "Cannot move the item to that location.")
        case .notConnected:
            return String(localized: "Not connected to a remote host. Connect first, then drop the items.")
        case .emptyPayload:
            return String(localized: "Nothing to transfer from that drop.")
        case .unreadableSource:
            return String(localized: "One or more dropped items could not be read.")
        }
    }
}
