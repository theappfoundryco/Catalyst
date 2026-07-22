import XCTest
@testable import Catalyst

@MainActor
final class BrewPathManagerTests: XCTestCase {
    
    // MARK: - Singleton & Architecture Tests
    
    func testSingletonAccess() {
        let instance1 = BrewPathManager.shared
        let instance2 = BrewPathManager.shared
        XCTAssertTrue(instance1 === instance2, "BrewPathManager should be a singleton")
    }
    
    func testArchitectureDetection() async {
        let manager = BrewPathManager.shared
        switch manager.architecture {
        case .appleSilicon:
            XCTAssertEqual(manager.architectureDescription, "Apple Silicon (ARM64)")
            let prefix = await manager.homebrewPrefix
            XCTAssertTrue(prefix.contains("/opt/homebrew") || prefix.contains("/usr/local")) // Fallback if rosetta
        case .intel:
            XCTAssertEqual(manager.architectureDescription, "Intel (x86_64)")
            let prefix = await manager.homebrewPrefix
            XCTAssertEqual(prefix, "/usr/local")
        case .unknown:
            XCTAssertEqual(manager.architectureDescription, "Unknown")
        }
    }
    
    // MARK: - Path Logic Tests
    
    func testPaths() async {
        let manager = BrewPathManager.shared
        let prefix = await manager.homebrewPrefix
        
        let python3Path = await manager.binPath("python3")
        XCTAssertEqual(python3Path, "\(prefix)/bin/python3")
        
        let cellar = await manager.cellarPath
        XCTAssertEqual(cellar, "\(prefix)/Cellar")
        
        let caskroom = await manager.caskroomPath
        XCTAssertEqual(caskroom, "\(prefix)/Caskroom")
        
        XCTAssertTrue(manager.cachePath.contains("/Library/Caches/Homebrew"))
    }
    
    func testBinPathConstruction() async {
        let manager = BrewPathManager.shared
        let toolName = "test-tool"
        let prefix = await manager.homebrewPrefix
        let expected = "\(prefix)/bin/\(toolName)"
        let actual = await manager.binPath(toolName)
        XCTAssertEqual(actual, expected)
    }
    
    // MARK: - Integration Tests (Smoke Tests)
    
    func testIsInstalled() async {
        // This test might fail if brew is literally not installed on the machine running tests.
        // However, for a dev machine, it usually is. We'll just assert it doesn't crash.
        let installed = await BrewPathManager.shared.isInstalled
        print("Brew installed: \(installed)")
    }
    
    func testGetInstalledPythons() async {
        let pythons = await BrewPathManager.shared.getInstalledPythons()
        // We can't guarantee pythons exist, but we can verify the array structure/sorting if any exist
        if !pythons.isEmpty {
             // Should be sorted descending
            let first = pythons.first!
            let last = pythons.last!
            
            if pythons.count > 1 {
                XCTAssertTrue(VersionComparator.compare(first.version, last.version) >= 0)
            }
            
            XCTAssertTrue(first.path.contains("python"))
            XCTAssertTrue(first.displayName.contains("Homebrew"))
        }
    }
    
    // MARK: - Thread Safety
    
    func testConcurrency() async {
        let manager = BrewPathManager.shared
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { @MainActor in
                    _ = await manager.brewPath
                    _ = await manager.homebrewPrefix
                }
            }
        }
        
        XCTAssertTrue(true, "Concurrent access should not crash")
    }
}
