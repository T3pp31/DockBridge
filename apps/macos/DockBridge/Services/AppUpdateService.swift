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
        let release = try await fetchLatestRelease()
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

    private func fetchLatestRelease() async throws -> GitHubReleaseResponse {
        var request = URLRequest(url: AppUpdateConfig.releasesLatestURL)
        request.setValue(AppUpdateConfig.githubAPIAcceptHeader, forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AppUpdateServiceError.invalidResponse
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
