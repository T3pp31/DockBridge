import AppKit
import SwiftUI

/// NSWindow の minSize を設定し、SwiftUI ルートの frame 制約によるレイアウト固定を避ける。
struct WindowMinSizeModifier: NSViewRepresentable {
    let minWidth: CGFloat
    let minHeight: CGFloat

    func makeNSView(context: Context) -> MinSizeView {
        let view = MinSizeView()
        view.minWidth = minWidth
        view.minHeight = minHeight
        return view
    }

    func updateNSView(_ nsView: MinSizeView, context: Context) {
        nsView.minWidth = minWidth
        nsView.minHeight = minHeight
        nsView.applyMinSize()
    }

    final class MinSizeView: NSView {
        var minWidth: CGFloat = 960
        var minHeight: CGFloat = 640

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyMinSize()
        }

        func applyMinSize() {
            guard let window else { return }
            let size = NSSize(width: minWidth, height: minHeight)
            window.minSize = size
            window.contentMinSize = size
        }
    }
}

extension View {
    func windowMinSize(width: CGFloat, height: CGFloat) -> some View {
        background(WindowMinSizeModifier(minWidth: width, minHeight: height))
    }
}
