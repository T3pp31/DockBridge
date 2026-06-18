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

        guard VersionComparator.isNewer(latestVersion, than: currentVersion) else {
            return nil
        }

        if let skippedVersion, VersionComparator.normalize(skippedVersion) == latestVersion {
            return nil
        }

        let downloadURL = dmgDownloadURL(from: release) ?? release.htmlURL

        return AppUpdateInfo(
            version: latestVersion,
            downloadURL: downloadURL,
            releasePageURL: release.htmlURL
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

    private func dmgDownloadURL(from release: GitHubReleaseResponse) -> URL? {
        release.assets
            .first { $0.name.hasSuffix(AppUpdateConfig.dmgSuffix) }?
            .browserDownloadURL
    }
}
