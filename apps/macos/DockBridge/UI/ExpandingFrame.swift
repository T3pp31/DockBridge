import SwiftUI

/// 親コンテナのサイズ変化を追跡し、子ビューへ明示的なサイズを渡す。
struct ExpandingFrame<Content: View>: View {
    @State private var size: CGSize = .zero
    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Draw content even before a size is measured so a parent that
            // proposes no explicit size (e.g. vertical ScrollView) can derive
            // a nonzero frame from the content itself (issue #775).
            // Keep the measured size as an output, not a fixed proposal: on an
            // unspecified axis, the content must remain free to change its ideal size.
            content(size)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
            guard newSize != size else { return }
            size = newSize
        }
    }
}
