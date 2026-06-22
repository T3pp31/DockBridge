import Foundation

enum AppUpdateConfig {
    static let githubRepo = "T3pp31/DockBridge"
    static let releasesLatestURL = URL(string: "https://api.github.com/repos/T3pp31/DockBridge/releases/latest")!
    static let githubAPIAcceptHeader = "application/vnd.github+json"

    static let allowedDownloadHosts: Set<String> = ["github.com", "objects.githubusercontent.com"]
    static let githubReleaseDownloadPathPrefix = "/T3pp31/DockBridge/releases/download/"
    static let githubReleasePagePathPrefix = "/T3pp31/DockBridge/releases/"
    static let appName = "DockBridge"

    static func expectedAssetName(for version: String) -> String {
        "\(appName)-\(version)-macOS.dmg"
    }
}
