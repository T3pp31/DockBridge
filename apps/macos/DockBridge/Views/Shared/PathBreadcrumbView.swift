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

                    Button(segment.title) {
                        onSelect(segment.path)
                    }
                    .buttonStyle(.plain)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .help(segment.path)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
