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

        guard let window = Self.previewHostWindow(
            keyWindow: NSApp.keyWindow,
            mainWindow: NSApp.mainWindow,
            windows: NSApp.windows
        ),
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
            self.nextResponder = previousNextResponder
            hostContentView = contentView
        }

        // The panel does not observe dataSource changes; refresh the visible
        // state so a new preview replaces the current one (issue #776).
        panel.currentPreviewItemIndex = 0
        panel.reloadData()

        panel.makeKeyAndOrderFront(nil)
    }

    static func previewHostWindow(
        keyWindow: NSWindow?,
        mainWindow: NSWindow?,
        windows: [NSWindow]
    ) -> NSWindow? {
        // The preview panel becomes key while visible. Never insert this
        // presenter into the panel's own responder chain, including on fallback.
        if let keyWindow, !(keyWindow is QLPreviewPanel) {
            return keyWindow
        }
        if let mainWindow, !(mainWindow is QLPreviewPanel) {
            return mainWindow
        }
        return windows.first { !($0 is QLPreviewPanel) && $0.isVisible }
    }

    private func detachFromResponderChain() {
        if let host = hostContentView, host.nextResponder === self {
            host.nextResponder = previousNextResponder
        }
        nextResponder = nil
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
        // Keep the URLs until the panel is shown again. Clearing them here
        // emptied the panel when it regained key status without a new
        // beginPreviewPanelControl callback.
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        // Guard against stale indices when the URL list shrinks (issue #776).
        guard previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index] as QLPreviewItem
    }
}
