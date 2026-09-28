import Foundation

/// Persisted release-body cache entry with a freshness timestamp.
struct ReleaseBodyCacheEntry: Codable {
    let storedAt: Date
    let body: Data
}

enum AppUpdateConfig {
    static let githubRepo = "T3pp31/DockBridge"
    static let releasesLatestURL = URL(string: "https://api.github.com/repos/T3pp31/DockBridge/releases/latest")!
    static let githubAPIAcceptHeader = "application/vnd.github+json"
    static let githubAPIVersion = "2022-11-28"

    /// User-Agent sent to api.github.com (GitHub requires one and recommends
    /// an identifiable client).
    static var userAgent: String {
        "DockBridge/\(VersionComparator.currentAppVersion) (macOS)"
    }

    /// Stored `ETag` from the last successful release check, sent as
    /// `If-None-Match` on the next check to conserve the unauthenticated
    /// rate limit (60 req/h/IP).
    static let etagDefaultsKey = "updateCheckETag"
    static func persistETag(_ etag: String) {
        UserDefaults.standard.set(etag, forKey: etagDefaultsKey)
    }
    static func showExistingETag() -> String? {
        UserDefaults.standard.string(forKey: etagDefaultsKey)
    }

    /// Cached, decoded release body from the last successful 200 response.
    /// Used to re-evaluate `304 Not Modified` responses: the ETag only tells
    /// us the *server* payload is unchanged, not that the update was applied.
    ///
    /// Stored on disk (not UserDefaults) because release metadata can be
    /// several KB and is re-read on 304 handling; the cache also carries a
    /// timestamp so stale entries are invalidated after a day.
    static let releaseBodyCacheFileName = "updateCheckReleaseBody.json"
    static let releaseBodyCacheMaxAge: TimeInterval = 24 * 60 * 60

    private static func releaseBodyCacheURL() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent(releaseBodyCacheFileName, isDirectory: false)
    }

    static func persistReleaseBody(_ body: Data) {
        do {
            let entry = ReleaseBodyCacheEntry(storedAt: Date(), body: body)
            let data = try JSONEncoder().encode(entry)
            try data.write(to: releaseBodyCacheURL(), options: .atomic)
        } catch {
            // Cache failures must never break the update check.
        }
    }

    static func showCachedReleaseBody() -> Data? {
        guard let data = try? Data(contentsOf: releaseBodyCacheURL()),
              let entry = try? JSONDecoder().decode(ReleaseBodyCacheEntry.self, from: data) else {
            return nil
        }
        guard Date().timeIntervalSince(entry.storedAt) <= releaseBodyCacheMaxAge else {
            clearReleaseBody()
            return nil
        }
        return entry.body
    }

    static func clearReleaseBody() {
        try? FileManager.default.removeItem(at: releaseBodyCacheURL())
    }

    static let allowedDownloadHosts: Set<String> = ["github.com", "objects.githubusercontent.com"]
    static let githubReleaseDownloadPathPrefix = "/T3pp31/DockBridge/releases/download/"
    static let githubReleasePagePathPrefix = "/T3pp31/DockBridge/releases/"
    static let appName = "DockBridge"
    static let bundleIdentifier = "com.dockbridge.app"

    // Keep in sync with config/release.toml. Enable when SIGN_AND_NOTARIZE=true.
    static let expectedTeamIdentifier = ""
    static let signingCertificateFingerprintSHA256 = ""
    static let requireSignedUpdates = false
    static let requireNotarizedUpdates = false

    /// In-app update installation (download → verify → mount DMG) is only allowed when
    /// Developer ID signature and/or notarization verification is enabled.
    static var inAppUpdateInstallationEnabled: Bool {
        requireSignedUpdates || requireNotarizedUpdates
    }

    static func expectedAssetName(for version: String) -> String {
        "\(appName)-\(version)-macOS.dmg"
    }

    static func expectedChecksumAssetName(for version: String) -> String {
        "\(expectedAssetName(for: version)).sha256"
    }
}
