import Foundation

/// How transfers should treat an existing destination file.
///
/// `ask` is resolved by the Swift UI into `ResolvedTransferOverwritePolicy`
/// before calling the bridge. Only `replace` or `failIfExists` can cross UniFFI
/// to the Rust transfer engine.
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

    func resolvedForBridge() throws -> ResolvedTransferOverwritePolicy {
        switch self {
        case .replace:
            return .replace
        case .failIfExists:
            return .failIfExists
        case .ask:
            throw DockBridgeError.Config(
                message: "Unresolved overwrite policy '.ask' must be resolved to '.replace' or '.failIfExists' before transfer."
            )
        }
    }
}

/// Overwrite policy already resolved by the UI and safe to pass to the Rust
/// transfer engine. Excludes `.ask` so an unconfirmed prompt can never degrade
/// into an unconditional replace (issue #1376).
enum ResolvedTransferOverwritePolicy: String, Equatable, Sendable {
    case replace
    case failIfExists
}
