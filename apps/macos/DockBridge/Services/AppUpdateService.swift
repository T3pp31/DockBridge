import Foundation

protocol URLSessionDataProviding: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionDataProviding {}

struct GitHubReleaseResponse: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

enum AppUpdateServiceError: Error, Equatable {
    case invalidResponse
    /// GitHub rate-limited us (403/429) after `If-None-Match` handled 304s.
    /// `retryAfter` is the server-provided Retry-After header when present.
    case rateLimited(retryAfter: String?)
}

final class AppUpdateService: @unchecked Sendable {
    private let session: URLSessionDataProviding

    init(session: URLSessionDataProviding = URLSession.shared) {
        self.session = session
    }

    func checkForUpdate(
        currentVersion: String = VersionComparator.currentAppVersion,
        skippedVersion: String?
    ) async throws -> AppUpdateInfo? {
        // 304 Not Modified (server matches our stored ETag) means no new release.
        guard let release = try await fetchLatestRelease() else {
            return nil
        }
        let latestVersion = VersionComparator.normalize(release.tagName)

        guard VersionComparator.isNewerStrict(latestVersion, than: currentVersion) else {
            return nil
        }

        if let skippedVersion, VersionComparator.normalize(skippedVersion) == latestVersion {
            return nil
        }

        let dmgDownloadURL = dmgDownloadURL(from: release, version: latestVersion)
        let checksumURL = checksumDownloadURL(from: release, version: latestVersion)
        let releasePageURL = validatedReleasePageURL(release.htmlURL)

        let downloadURL: URL?
        if let dmgDownloadURL, let checksumURL {
            downloadURL = dmgDownloadURL
        } else if let releasePageURL {
            downloadURL = releasePageURL
        } else {
            downloadURL = dmgDownloadURL
        }

        guard let downloadURL else {
            return nil
        }

        let resolvedReleasePageURL = releasePageURL ?? downloadURL

        return AppUpdateInfo(
            version: latestVersion,
            downloadURL: downloadURL,
            checksumURL: checksumURL,
            releasePageURL: resolvedReleasePageURL
        )
    }

    private func fetchLatestRelease() async throws -> GitHubReleaseResponse? {
        var request = URLRequest(url: AppUpdateConfig.releasesLatestURL)
        // Keep startup snappy even when api.github.com is slow / blocked.
        request.timeoutInterval = 15
        request.setValue(AppUpdateConfig.githubAPIAcceptHeader, forHTTPHeaderField: "Accept")
        request.setValue(VersionComparator.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(AppUpdateConfig.githubAPIVersion, forHTTPHeaderField: "X-GitHub-Api-Version")

        let savedETag = AppUpdateConfig.showExistingETag()
        if let savedETag {
            request.setValue(savedETag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateServiceError.invalidResponse
        }

        // 304: the stored ETag matched; no new release.
        if httpResponse.statusCode == 304 {
            return nil
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // 403 / 429 are rate-limit responses: surface them distinctly so
            // the caller does not treat the failure as "no update available".
            if httpResponse.statusCode == 403 || httpResponse.statusCode == 429 {
                let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                throw AppUpdateServiceError.rateLimited(retryAfter: retryAfter)
            }
            throw AppUpdateServiceError.invalidResponse
        }

        // Remember the ETag so the next launch can send If-None-Match and avoid
        // burning GitHub's unauthenticated rate limit (60 req/h/IP).
        if let etag = httpResponse.value(forHTTPHeaderField: "ETag") {
            AppUpdateConfig.persistETag(etag)
        }

        return try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
    }

    private func dmgDownloadURL(from release: GitHubReleaseResponse, version: String) -> URL? {
        let expectedAssetName = AppUpdateConfig.expectedAssetName(for: version)
        guard let asset = release.assets.first(where: { $0.name == expectedAssetName }) else {
            return nil
        }
        return validatedDownloadURL(asset.browserDownloadURL, expectedAssetName: expectedAssetName)
    }

    private func checksumDownloadURL(from release: GitHubReleaseResponse, version: String) -> URL? {
        let expectedAssetName = AppUpdateConfig.expectedChecksumAssetName(for: version)
        guard let asset = release.assets.first(where: { $0.name == expectedAssetName }) else {
            return nil
        }
        return validatedDownloadURL(asset.browserDownloadURL, expectedAssetName: expectedAssetName)
    }

    private func validatedDownloadURL(_ url: URL, expectedAssetName: String) -> URL? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              AppUpdateConfig.allowedDownloadHosts.contains(host) else {
            return nil
        }

        switch host {
        case "github.com":
            guard url.path.hasPrefix(AppUpdateConfig.githubReleaseDownloadPathPrefix),
                  url.lastPathComponent == expectedAssetName else {
                return nil
            }
        case "objects.githubusercontent.com":
            guard url.lastPathComponent == expectedAssetName else {
                return nil
            }
        default:
            return nil
        }

        return url
    }

    private func validatedReleasePageURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.path.hasPrefix(AppUpdateConfig.githubReleasePagePathPrefix) else {
            return nil
        }
        return url
    }
}
