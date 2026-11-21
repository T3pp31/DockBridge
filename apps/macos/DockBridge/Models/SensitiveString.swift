import Foundation
import Observation

/// Holds sensitive text entered in the UI and supports explicit clearing.
///
/// Swift `String` does not expose mutable storage and cannot be safely
/// zeroized. This type therefore uses a final class to keep the mutable buffer
/// shared by all aliases; `clear()` zeroizes that same buffer instead of
/// creating a copy-on-write duplicate. Accessing `text` still creates a
/// temporary String required by SwiftUI; callers should avoid retaining it.
@Observable
final class SensitiveString: Equatable {
    /// `@ObservationIgnored` keeps this a true stored property. Without it the
    /// macro rewrites `storage` into a computed property backed by `_storage`,
    /// so `resetBytes` would copy-on-write and zeroize a fresh copy instead of
    /// the buffer holding the plaintext (issue #1145).
    ///
    /// Readable (not writable) outside the class so tests can assert that the
    /// bytes are overwritten in place; writes must go through `text` or
    /// `clear()` so the old buffer is zeroized and observers are notified.
    @ObservationIgnored private(set) var storage = Data()

    deinit {
        // `clear()` is not guaranteed before release (e.g. an abandoned
        // prompt); zeroize on the way out too.
        zeroizeInPlace()
    }

    static func == (lhs: SensitiveString, rhs: SensitiveString) -> Bool {
        lhs.storage == rhs.storage
    }

    var text: String {
        get {
            // `storage` is ignored by @Observable to stay a stored property,
            // so register the dependency on `text` explicitly; otherwise
            // SwiftUI would not refresh after clear() or a set (issue #1145).
            _$observationRegistrar.access(self, keyPath: \.text)
            return String(decoding: storage, as: UTF8.self)
        }
        set {
            _$observationRegistrar.withMutation(of: self, keyPath: \.text) {
                zeroizeStorage()
                storage = Data(newValue.utf8)
            }
        }
    }

    /// Zeroizes and empties the secret. Like any Observation mutation,
    /// `onChange` observers fire before the change is applied, so they must
    /// re-read `text` later (as SwiftUI does) rather than inside the callback.
    func clear() {
        _$observationRegistrar.withMutation(of: self, keyPath: \.text) {
            zeroizeStorage()
        }
    }

    private func zeroizeStorage() {
        zeroizeInPlace()
        storage.removeAll(keepingCapacity: false)
    }

    /// Overwrites the current buffer with zeros without reallocating it.
    /// Internal so tests can verify the same buffer is overwritten.
    func zeroizeInPlace() {
        if !storage.isEmpty {
            // Data exposes supported mutable storage; resetBytes overwrites
            // that storage without casting away constness from a String.
            storage.resetBytes(in: 0..<storage.count)
        }
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
