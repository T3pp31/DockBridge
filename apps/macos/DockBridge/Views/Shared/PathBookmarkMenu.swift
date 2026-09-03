import SwiftUI

struct PathBookmarkMenu: View {
    let bookmarks: [PathBookmark]
    let onBookmarkCurrent: () -> Void
    let onSelect: (PathBookmark) -> Void
    let onRemove: (PathBookmark) -> Void

    var body: some View {
        Menu {
            Button("Bookmark This Path", action: onBookmarkCurrent)

            if !bookmarks.isEmpty {
                Divider()
                ForEach(bookmarks) { bookmark in
                    Button(bookmark.name) {
                        onSelect(bookmark)
                    }
                    .contextMenu {
                        Button("Remove Bookmark", role: .destructive) {
                            onRemove(bookmark)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "star")
        }
        .help("Path bookmarks")
        .menuStyle(.borderlessButton)
    }
}
