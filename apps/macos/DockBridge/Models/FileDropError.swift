import Foundation

enum FileDropError: LocalizedError {
    case invalidMove
    case notConnected
    case emptyPayload
    case unreadableSource

    var errorDescription: String? {
        switch self {
        case .invalidMove:
            return "Cannot move the item to that location."
        case .notConnected:
            return "Not connected to a remote host. Connect first, then drop the items."
        case .emptyPayload:
            return "Nothing to transfer from that drop."
        case .unreadableSource:
            return "One or more dropped items could not be read."
        }
    }
}
