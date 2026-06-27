import Foundation
import XCTest
@testable import DockBridge

private struct MockURLSession: URLSessionDataProviding {
    let data: Data
    let response: HTTPURLResponse

    init(statusCode: Int, data: Data) {
        self.data = data
        self.response = HTTPURLResponse(
            url: AppUpdateConfig.releasesLatestURL,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (data, response)
    }
}

final class AppUpdateServiceTests: XCTestCase {
    private let validDownloadURL =
        "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg"
    private let releasePageURL = "https://github.com/T3pp31/DockBridge/releases/tag/v0.2.0"

    func testCheckForUpdateReturnsInfoWhenNewerVersionAvailable() async throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "html_url": "\(releasePageURL)",
          "assets": [
            {
              "name": "DockBridge-0.2.0-macOS.dmg",
              "browser_download_url": "\(validDownloadURL)"
            },
            {
              "name": "DockBridge-0.2.0-macOS.dmg.sha256",
              "browser_download_url": "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg.sha256"
            }
          ]
        }
        """.data(using: .utf8)!

        let service = AppUpdateService(session: MockURLSession(statusCode: 200, data: json))
        let update = try await service.checkForUpdate(currentVersion: "0.1.0", skippedVersion: nil)

        XCTAssertEqual(update?.version, "0.2.0")
        XCTAssertEqual(update?.downloadURL.absoluteString, validDownloadURL)
        XCTAssertEqual(
            update?.checksumURL?.absoluteString,
            "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg.sha256"
        )
        XCTAssertEqual(update?.releasePageURL.absoluteString, releasePageURL)
    }

    func testCheckForUpdateReturnsNilWhenCurrentVersionIsLatest() async throws {
        let json = """
        {
          "tag_name": "v0.1.2",
          "html_url": "https://github.com/T3pp31/DockBridge/releases/tag/v0.1.2",
          "assets": []
        }
        """.data(using: .utf8)!

        let service = AppUpdateService(session: MockURLSession(statusCode: 200, data: json))
        let update = try await service.checkForUpdate(currentVersion: "0.1.2", skippedVersion: nil)

        XCTAssertNil(update)
    }

    func testCheckForUpdateReturnsNilWhenVersionWasSkipped() async throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "html_url": "\(releasePageURL)",
          "assets": [
            {
              "name": "DockBridge-0.2.0-macOS.dmg",
              "browser_download_url": "\(validDownloadURL)"
            },
            {
              "name": "DockBridge-0.2.0-macOS.dmg.sha256",
              "browser_download_url": "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg.sha256"
            }
          ]
        }
        """.data(using: .utf8)!

        let service = AppUpdateService(session: MockURLSession(statusCode: 200, data: json))
        let update = try await service.checkForUpdate(currentVersion: "0.1.0", skippedVersion: "0.2.0")

        XCTAssertNil(update)
    }

    func testCheckForUpdateFallsBackToReleasePageWhenDmgMissing() async throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "html_url": "\(releasePageURL)",
          "assets": []
        }
        """.data(using: .utf8)!

        let service = AppUpdateService(session: MockURLSession(statusCode: 200, data: json))
        let update = try await service.checkForUpdate(currentVersion: "0.1.0", skippedVersion: nil)

        XCTAssertEqual(update?.downloadURL.absoluteString, releasePageURL)
    }

    func testCheckForUpdateRejectsUntrustedDownloadURLAndFallsBackToReleasePage() async throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "html_url": "\(releasePageURL)",
          "assets": [
            {
              "name": "DockBridge-0.2.0-macOS.dmg",
              "browser_download_url": "https://example.com/DockBridge-0.2.0-macOS.dmg"
            }
          ]
        }
        """.data(using: .utf8)!

        let service = AppUpdateService(session: MockURLSession(statusCode: 200, data: json))
        let update = try await service.checkForUpdate(currentVersion: "0.1.0", skippedVersion: nil)

        XCTAssertEqual(update?.downloadURL.absoluteString, releasePageURL)
    }

    func testCheckForUpdateRejectsHTTPScheme() async throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "html_url": "\(releasePageURL)",
          "assets": [
            {
              "name": "DockBridge-0.2.0-macOS.dmg",
              "browser_download_url": "http://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg"
            }
          ]
        }
        """.data(using: .utf8)!

        let service = AppUpdateService(session: MockURLSession(statusCode: 200, data: json))
        let update = try await service.checkForUpdate(currentVersion: "0.1.0", skippedVersion: nil)

        XCTAssertEqual(update?.downloadURL.absoluteString, releasePageURL)
    }

    func testCheckForUpdateRejectsUnexpectedAssetName() async throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "html_url": "\(releasePageURL)",
          "assets": [
            {
              "name": "DockBridge-0.2.0-macOS-evil.dmg",
              "browser_download_url": "\(validDownloadURL)"
            }
          ]
        }
        """.data(using: .utf8)!

        let service = AppUpdateService(session: MockURLSession(statusCode: 200, data: json))
        let update = try await service.checkForUpdate(currentVersion: "0.1.0", skippedVersion: nil)

        XCTAssertEqual(update?.downloadURL.absoluteString, releasePageURL)
    }

    func testCheckForUpdateAcceptsValidGitHubReleaseDownloadURL() async throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "html_url": "\(releasePageURL)",
          "assets": [
            {
              "name": "DockBridge-0.2.0-macOS.dmg",
              "browser_download_url": "\(validDownloadURL)"
            },
            {
              "name": "DockBridge-0.2.0-macOS.dmg.sha256",
              "browser_download_url": "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg.sha256"
            }
          ]
        }
        """.data(using: .utf8)!

        let service = AppUpdateService(session: MockURLSession(statusCode: 200, data: json))
        let update = try await service.checkForUpdate(currentVersion: "0.1.0", skippedVersion: nil)

        XCTAssertEqual(update?.downloadURL.absoluteString, validDownloadURL)
    }

    func testCheckForUpdateAcceptsObjectsGitHubusercontentURL() async throws {
        let objectsURL =
            "https://objects.githubusercontent.com/github-production-release-asset-2e65be/123/DockBridge-0.2.0-macOS.dmg"
        let json = """
        {
          "tag_name": "v0.2.0",
          "html_url": "\(releasePageURL)",
          "assets": [
            {
              "name": "DockBridge-0.2.0-macOS.dmg",
              "browser_download_url": "\(objectsURL)"
            }
          ]
        }
        """.data(using: .utf8)!

        let service = AppUpdateService(session: MockURLSession(statusCode: 200, data: json))
        let update = try await service.checkForUpdate(currentVersion: "0.1.0", skippedVersion: nil)

        XCTAssertEqual(update?.downloadURL.absoluteString, objectsURL)
    }

    func testCheckForUpdateReturnsNilWhenBothURLsUntrusted() async throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "html_url": "https://example.com/releases/tag/v0.2.0",
          "assets": [
            {
              "name": "DockBridge-0.2.0-macOS.dmg",
              "browser_download_url": "https://example.com/DockBridge-0.2.0-macOS.dmg"
            }
          ]
        }
        """.data(using: .utf8)!

        let service = AppUpdateService(session: MockURLSession(statusCode: 200, data: json))
        let update = try await service.checkForUpdate(currentVersion: "0.1.0", skippedVersion: nil)

        XCTAssertNil(update)
    }

    func testCheckForUpdateThrowsOnInvalidResponse() async {
        let service = AppUpdateService(session: MockURLSession(statusCode: 500, data: Data()))

        do {
            _ = try await service.checkForUpdate(currentVersion: "0.1.0", skippedVersion: nil)
            XCTFail("Expected invalidResponse error")
        } catch let error as AppUpdateServiceError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
