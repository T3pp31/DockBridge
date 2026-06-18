import Foundation

struct AppUpdateInfo: Equatable, Identifiable {
    let version: String
    let downloadURL: URL
    let releasePageURL: URL

    var id: String { version }
}
