import AppKit
import SwiftUI

struct PathSummaryRow<Actions: View>: View {
    let label: String
    let path: String
    var showRevealInFinder: Bool = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Spacer(minLength: 0)

                actions()

                Button {
                    ClipboardHelper.copy(path)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Copy path")

                if showRevealInFinder {
                    Button {
                        revealInFinder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help("Reveal in Finder")
                }
            }

            Text(path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func revealInFinder() {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        NSWorkspace.shared.open(url)
    }
}

extension PathSummaryRow where Actions == EmptyView {
    init(label: String, path: String, showRevealInFinder: Bool = false) {
        self.label = label
        self.path = path
        self.showRevealInFinder = showRevealInFinder
        self.actions = { EmptyView() }
    }
}
