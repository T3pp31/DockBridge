import Foundation

/// How transfers should treat an existing destination file.
///
/// `ask` is resolved by the Swift UI. The resulting `replace` or
/// `failIfExists` policy is passed through UniFFI and enforced by the Rust
/// transfer engine.
enum TransferOverwritePolicy: String, Codable, CaseIterable, Sendable {
    case replace
    case failIfExists
    case ask

    var label: String {
        switch self {
        case .replace: return String(localized: "Replace")
        case .failIfExists: return String(localized: "Fail if exists")
        case .ask: return String(localized: "Ask")
        }
    }
}
