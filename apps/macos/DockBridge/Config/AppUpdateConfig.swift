import Foundation

enum AppUpdateConfig {
    static let githubRepo = "T3pp31/DockBridge"
    static let releasesLatestURL = URL(string: "https://api.github.com/repos/T3pp31/DockBridge/releases/latest")!
    static let dmgSuffix = ".dmg"
    static let githubAPIAcceptHeader = "application/vnd.github+json"
}
