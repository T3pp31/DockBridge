import Darwin
import Foundation

/// Holds sensitive text entered in the UI and supports explicit clearing.
///
/// Swift `String` is immutable and does not guarantee memory zeroing.
/// `zeroize` uses `withUTF8` to access the string's internal contiguous
/// UTF-8 buffer and overwrites it in place. This is best-effort: when the
/// string's storage is shared (Copy-on-Write) the original buffer is not
/// touched. In practice, credentials held in `SensitiveString` are unique
/// owners of their storage, so the buffer is cleared. The Rust core also
/// wraps secrets in `Zeroizing`, which is the authoritative clearing path.
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
        // Overwrite the string's internal UTF-8 buffer in place. withUTF8
        // provides a borrowed pointer to the contiguous storage; when the
        // string is the sole owner (no COW sharing) this zeroes the actual
        // backing memory rather than a temporary copy.
        value.withUTF8 { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return }
            memset(UnsafeMutableRawPointer(mutating: base), 0, buffer.count)
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
