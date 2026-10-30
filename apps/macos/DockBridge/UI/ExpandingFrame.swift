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
            content(size)
                .frame(
                    width: size.width > 0 ? size.width : nil,
                    height: size.height > 0 ? size.height : nil,
                    alignment: .topLeading
                )
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
            guard newSize != size else { return }
            size = newSize
        }
    }
}
