import XCTest
@testable import Catalyst

final class NetworkConfigTests: XCTestCase {
    
    // MARK: - Constants Tests
    
    func testBaseURLs() {
        XCTAssertEqual(NetworkConfig.APIEndpoint.baseURL, "https://setitup.pages.dev")
        XCTAssertEqual(NetworkConfig.APIEndpoint.shortcutsURL, "https://setitup.pages.dev/shortcuts")
        XCTAssertEqual(NetworkConfig.APIEndpoint.publicURL, "https://setitup.pages.dev/public")
        XCTAssertEqual(NetworkConfig.APIEndpoint.brewURL, "https://setitup.pages.dev/public/brew")
        XCTAssertEqual(NetworkConfig.APIEndpoint.pypiURL, "https://setitup.pages.dev/public/pypi")
        XCTAssertEqual(NetworkConfig.APIEndpoint.popularURL, "https://setitup.pages.dev/public/popular")
    }
    
    func testFileEndpoints() {
        XCTAssertEqual(NetworkConfig.APIEndpoint.brewFormulaeURL, "https://setitup.pages.dev/public/brew/homebrew_formulae.json")
        XCTAssertEqual(NetworkConfig.APIEndpoint.brewCasksURL, "https://setitup.pages.dev/public/brew/homebrew_casks.json")
        // aboutURL removed — About/What's-new is bundled in the app, not fetched.
    }
    
    // MARK: - Session Configuration Tests
    
    func testApiSessionConfiguration() {
        let session = NetworkConfig.apiSession
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 30)
        XCTAssertFalse(session.configuration.waitsForConnectivity)
    }
    
    func testDownloadSessionConfiguration() {
        let session = NetworkConfig.downloadSession
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 120)
        XCTAssertFalse(session.configuration.waitsForConnectivity)
    }
    
    // MARK: - Error Tests
    
    func testNetworkErrorDescriptions() {
        let invalidResponse = NetworkConfig.NetworkError.invalidResponse
        XCTAssertEqual(invalidResponse.errorDescription, "Invalid response from server")
        
        let httpError = NetworkConfig.NetworkError.httpError(statusCode: 404)
        XCTAssertEqual(httpError.errorDescription, "HTTP error: 404")
        
        let underlying = NSError(domain: "test", code: 1, userInfo: nil)
        let decodingError = NetworkConfig.NetworkError.decodingError(underlying: underlying)
        XCTAssertTrue(decodingError.errorDescription?.contains("Failed to decode") == true)
    }
    
    // MARK: - fetchJSON Tests (Mocked)
    
    // We cannot easily mock the static URLSession in NetworkConfig without refactoring it.
    // So we will skip integration testing fetchJSON to avoid flaky network calls,
    // and rely on the configuration tests above.
    
}
