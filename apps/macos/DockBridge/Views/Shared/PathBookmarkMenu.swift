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
                }

                Divider()
                Menu("Remove Bookmark") {
                    ForEach(bookmarks) { bookmark in
                        Button(bookmark.name, role: .destructive) {
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
