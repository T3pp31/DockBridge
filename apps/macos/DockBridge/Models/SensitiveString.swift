import Darwin
import Foundation

/// Holds sensitive text entered in the UI and supports explicit clearing.
///
/// Swift `String` does not guarantee memory zeroing. Clearing uses a `Data` buffer
/// with explicit `memset` to reduce how long credentials remain in memory after dismiss.
struct SensitiveString: Equatable {
    var text = ""

    mutating func clear() {
        Self.zeroize(&text)
    }

    static func clear(_ value: inout String) {
        zeroize(&value)
    }

    static func clear(_ value: inout String?) {
        if var current = value {
            zeroize(&current)
        }
        value = nil
    }

    private static func zeroize(_ value: inout String) {
        guard var data = value.data(using: .utf8) else {
            value = ""
            return
        }
        data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            memset(baseAddress, 0, buffer.count)
        }
        value = ""
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
