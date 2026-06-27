import SwiftUI

struct PathBreadcrumbView: View {
    let segments: [PathBreadcrumb.Segment]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    PathBreadcrumbSegmentButton(
                        segment: segment,
                        isCurrent: index == segments.count - 1,
                        onSelect: onSelect
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PathBreadcrumbSegmentButton: View {
    let segment: PathBreadcrumb.Segment
    let isCurrent: Bool
    let onSelect: (String) -> Void

    @State private var isHovered = false

    var body: some View {
        Button(segment.title) {
            onSelect(segment.path)
        }
        .buttonStyle(.plain)
        .font(.caption.monospaced())
        .fontWeight(isCurrent ? .semibold : .regular)
        .foregroundStyle(isCurrent ? .primary : .secondary)
        .lineLimit(1)
        .help(segment.path)
        .accessibilityLabel(segment.path)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: Capsule())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
