import SwiftUI

struct DropTargetOverlay: View {
    let title: String
    let systemImage: String

    @Environment(\.colorScheme) private var colorScheme

    private let cornerRadius: CGFloat = DesignTokens.CornerRadius.medium

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tintFill)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1)

            Label(title, systemImage: systemImage)
                .font(.title3.weight(.medium))
                .foregroundStyle(labelColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .allowsHitTesting(false)
    }

    private var tintFill: Color {
        switch colorScheme {
        case .dark:
            Color.accentColor.opacity(0.18)
        default:
            Color.accentColor.opacity(0.12)
        }
    }

    private var labelColor: Color {
        switch colorScheme {
        case .dark:
            Color.primary.opacity(0.92)
        default:
            Color.primary.opacity(0.88)
        }
    }
}
