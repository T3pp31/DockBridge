import Foundation

/// Holds sensitive text entered in the UI and supports explicit clearing.
///
/// Swift `String` does not expose mutable storage and cannot be safely
/// zeroized. This type therefore keeps its authoritative storage in `Data`,
/// whose mutable bytes can be explicitly cleared. Accessing `text` still
/// creates a temporary String required by SwiftUI; callers should avoid
/// retaining that value.
struct SensitiveString: Equatable {
    private var storage = Data()

    var text: String {
        get { String(decoding: storage, as: UTF8.self) }
        set {
            zeroizeStorage()
            storage = Data(newValue.utf8)
        }
    }

    mutating func clear() {
        zeroizeStorage()
    }

    private mutating func zeroizeStorage() {
        if !storage.isEmpty {
            // Data exposes supported mutable storage; resetBytes overwrites
            // that storage without casting away constness from a String.
            storage.resetBytes(in: 0..<storage.count)
        }
        storage.removeAll(keepingCapacity: false)
    }

    static func clear(_ value: inout String) {
        // String has no supported mutable-storage API. Discard the value
        // without casting away constness or invoking undefined behavior.
        value = ""
    }

    static func clear(_ value: inout String?) {
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
