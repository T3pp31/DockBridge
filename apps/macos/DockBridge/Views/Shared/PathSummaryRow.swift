import AppKit
import SwiftUI

struct PathSummaryRow: View {
    let label: String
    let path: String
    var showRevealInFinder: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            Text(path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                ClipboardHelper.copy(path)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy path")

            if showRevealInFinder {
                Button {
                    revealInFinder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
        }
    }

    private func revealInFinder() {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        NSWorkspace.shared.open(url)
    }
}
