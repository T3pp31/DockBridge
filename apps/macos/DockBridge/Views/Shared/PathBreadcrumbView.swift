import SwiftUI

struct PathBreadcrumbView: View {
    let segments: [PathBreadcrumb.Segment]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
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
                        .id(segment.id)
                    }
                }
            }
            .onAppear {
                scroll(proxy)
            }
            .onChange(of: segments) { _, _ in
                scroll(proxy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let last = segments.last else { return }
        proxy.scrollTo(last.id, anchor: .trailing)
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
