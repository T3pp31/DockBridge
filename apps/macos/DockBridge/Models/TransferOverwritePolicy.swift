import Foundation

/// How transfers should treat an existing destination file.
///
/// `ask` is handled in the Swift UI layer before starting a transfer (Issue #214).
/// `replace` and `failIfExists` mirror the Rust engine's `TransferOverwritePolicy`.
enum TransferOverwritePolicy: String, Codable, CaseIterable, Sendable {
    case replace
    case failIfExists
    case ask

    var label: String {
        switch self {
        case .replace: return "Replace"
        case .failIfExists: return "Fail if exists"
        case .ask: return "Ask"
        }
    }
}
