import Foundation

enum FileDropError: LocalizedError {
    case invalidMove

    var errorDescription: String? {
        switch self {
        case .invalidMove:
            return "Cannot move the item to that location."
        }
    }
}
