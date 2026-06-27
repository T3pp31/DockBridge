import SwiftUI

/// Shared layout for confirmation and notification sheets.
struct DialogCard<Content: View, Footer: View>: View {
    let title: String
    var titleSystemImage: String?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: DialogCardMetrics.contentSpacing) {
            titleRow

            content()

            HStack {
                Spacer()
                footer()
            }
        }
        .padding(DialogCardMetrics.padding)
        .frame(minWidth: DialogCardMetrics.minWidth)
        .background(.background, in: RoundedRectangle(cornerRadius: DialogCardMetrics.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var titleRow: some View {
        if let titleSystemImage {
            Label(title, systemImage: titleSystemImage)
                .font(.title2)
                .bold()
        } else {
            Text(title)
                .font(.title2)
                .bold()
        }
    }
}

private enum DialogCardMetrics {
    static let minWidth: CGFloat = 480
    static let padding: CGFloat = 28
    static let cornerRadius: CGFloat = 16
    static let contentSpacing: CGFloat = 16
}

/// Bordered detail block used inside dialog sheets.
struct DialogDetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        GroupBox(title) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Secondary guidance text below dialog body content.
struct DialogFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}
