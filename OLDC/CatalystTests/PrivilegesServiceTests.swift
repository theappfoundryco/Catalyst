import XCTest
@testable import Catalyst

final class PrivilegesServiceTests: XCTestCase {
    


    func testSafePaths() {
        let logger = Logger.shared
        let service = PrivilegesService(logger: logger)
        
        // Allowed paths
        XCTAssertTrue(service.validateSafeToDeletePath("/opt/homebrew/Cellar/python/3.9"))
        XCTAssertTrue(service.validateSafeToDeletePath("/usr/local/Cellar/node/14"))
        XCTAssertTrue(service.validateSafeToDeletePath(FileManager.default.homeDirectoryForCurrentUser.path + "/.local/share/virtualenvs/test"))
        
        // Specific file exception
        XCTAssertTrue(service.validateSafeToDeletePath("/opt/homebrew/AGENTS.md"))
    }
    
    func testUnsafePaths() {
        let logger = Logger.shared
        let service = PrivilegesService(logger: logger)
        
        // Blocked system paths
        XCTAssertFalse(service.validateSafeToDeletePath("/"))
        XCTAssertFalse(service.validateSafeToDeletePath("/System/Library"))
        XCTAssertFalse(service.validateSafeToDeletePath("/usr/bin/python"))
        XCTAssertFalse(service.validateSafeToDeletePath("/Applications/Safari.app"))
        
        // Blocked user home paths
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(service.validateSafeToDeletePath(home))
        XCTAssertFalse(service.validateSafeToDeletePath(home + "/Documents/Important.doc"))
        XCTAssertFalse(service.validateSafeToDeletePath(home + "/Desktop/Work"))
        XCTAssertFalse(service.validateSafeToDeletePath(home + "/Library/Keychains"))
        
        // Blocked random paths
        XCTAssertFalse(service.validateSafeToDeletePath("/var/db"))
        XCTAssertFalse(service.validateSafeToDeletePath("/tmp/unsafe"))
    }
}
