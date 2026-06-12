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
}
