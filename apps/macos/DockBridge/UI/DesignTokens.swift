import AppKit
import SwiftUI

/// Centralized design tokens for colors, corner radii, spacing, and typography.
///
/// Existing views that hard-coded values (status colors, corner radii, padding)
/// should reference these tokens so that light/dark consistency is preserved in
/// one place. See Issue #222.
enum DesignTokens {
    // MARK: Status colors

    enum Status {
        static var connected: Color { Color(nsColor: .systemGreen) }
        static var connecting: Color { Color(nsColor: .systemOrange) }
        static var disconnected: Color { Color(nsColor: .secondaryLabelColor) }
        static var success: Color { Color(nsColor: .systemGreen) }
        static var warning: Color { Color(nsColor: .systemOrange) }
        static var error: Color { Color(nsColor: .systemRed) }
    }

    // MARK: Corner radii

    enum CornerRadius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }

    // MARK: Spacing

    enum Spacing {
        static let componentPadding: CGFloat = 14
        static let panePadding: CGFloat = 12
        static let itemSpacing: CGFloat = 8
        static let tightSpacing: CGFloat = 4
        static let statusBarHorizontal: CGFloat = 12
        static let statusBarVertical: CGFloat = 6
    }

    // MARK: Fonts

    enum Fonts {
        static let statusTitle: Font = .subheadline
        static let secondaryDetail: Font = .caption
        static let monospacedDigit: Font = .subheadline.monospacedDigit()
    }
}
