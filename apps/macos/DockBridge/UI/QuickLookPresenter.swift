import AppKit
import Quartz

/// Presents the system Quick Look panel for local file URLs (Issue #228).
///
/// `QLPreviewPanel` follows the responder chain, so this helper temporarily
/// inserts itself as the content view's next responder before showing the panel.
final class QuickLookPresenter: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPresenter()

    private var previewURLs: [URL] = []
    private weak var hostContentView: NSView?
    private var previousNextResponder: NSResponder?

    private override init() {
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func preview(url: URL) {
        preview(urls: [url])
    }

    func preview(urls: [URL]) {
        let fileURLs = urls.filter { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        }
        guard !fileURLs.isEmpty else { return }
        previewURLs = fileURLs

        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
              let contentView = window.contentView,
              let panel = QLPreviewPanel.shared()
        else {
            // Responder-chain insertion failed; fall back to opening in the default app.
            fileURLs.forEach { NSWorkspace.shared.open($0) }
            return
        }

        if hostContentView !== contentView {
            detachFromResponderChain()
            previousNextResponder = contentView.nextResponder
            contentView.nextResponder = self
            hostContentView = contentView
        }

        panel.makeKeyAndOrderFront(nil)
    }

    private func detachFromResponderChain() {
        if let host = hostContentView, host.nextResponder === self {
            host.nextResponder = previousNextResponder
        }
        hostContentView = nil
        previousNextResponder = nil
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !previewURLs.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        detachFromResponderChain()
        previewURLs = []
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURLs[index] as QLPreviewItem
    }
}
