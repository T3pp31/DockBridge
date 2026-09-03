import Foundation

enum PathBookmarkPane: String, Codable, Sendable {
    case local
    case remote
}

struct PathBookmark: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var path: String
    var pane: PathBookmarkPane
    var profileID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        pane: PathBookmarkPane,
        profileID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.pane = pane
        self.profileID = profileID
    }
}
