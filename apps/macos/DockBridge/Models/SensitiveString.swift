import Foundation

/// Holds sensitive text entered in the UI and supports explicit clearing.
///
/// Swift `String` does not guarantee memory zeroing, but clearing on dismiss reduces
/// how long credentials remain in `@State` after the form closes.
struct SensitiveString: Equatable {
    var text = ""

    mutating func clear() {
        text = ""
    }

    static func clear(_ value: inout String) {
        value = ""
    }

    static func clear(_ value: inout String?) {
        if var current = value {
            current = ""
        }
        value = nil
    }
}

extension ConnectionProfileRecord {
    mutating func clearCredentials() {
        switch authType {
        case .password:
            authType = .password(password: "")
        case let .privateKey(keyPath, _):
            authType = .privateKey(keyPath: keyPath, passphrase: nil)
        }
    }
}
