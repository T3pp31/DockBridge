import Foundation

/// How transfers should treat an existing destination file.
///
/// `ask` and `failIfExists` are enforced in the Swift UI layer before starting a transfer
/// (Issue #214). The Rust engine still defaults to Replace until `AppConfigRecord` /
/// UniFFI expose `TransferOverwritePolicy` and `TransferManager` consumes it.
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
