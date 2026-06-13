import SwiftUI

/// 親コンテナのサイズ変化を追跡し、子ビューへ明示的なサイズを渡す。
struct ExpandingFrame<Content: View>: View {
    @State private var size: CGSize = .zero
    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            if size.width > 0, size.height > 0 {
                content(size)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
            guard newSize != size else { return }
            size = newSize
        }
    }
}
