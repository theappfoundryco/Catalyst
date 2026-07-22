import XCTest
@testable import Catalyst

/// 🚨 DESTRUCTIVE TESTS 🚨
/// These tests intentionally try to break the app by corrupting files, 
/// flooding concurrency, and passing invalid data.
final class DestructiveTests: XCTestCase {
    
    // MARK: - Persistence Corruption
    
    @MainActor func testProjectStore_CorruptedJSON() throws {
        // 1. Locate the storage file
        let fm = FileManager.default
        let appDir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("com.shivanggulati.catalyst")
        let url = appDir.appendingPathComponent("projects.json")
        
        // 2. Write garbage to it
        let garbage = "{ \"projects\": [ INVALID JSON HERE @#$@#$ ] }"
        try garbage.write(to: url, atomically: true, encoding: .utf8)
        
        // 3. Force reload
        // Even if shared is already loaded, calling load() should handle the file on disk
        ProjectStore.shared.load()
        
        // 4. Assert recovery
        // The store should either be empty or keep previous data, but likely empty if load failed.
        // It definitely should NOT crash.
        XCTAssertNotNil(ProjectStore.shared.projects)
        print("✅ ProjectStore survived corrupted JSON")
    }
    
    @MainActor
    func testConfigStore_CorruptedJSON() throws {
        let fm = FileManager.default
        let appDir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("com.shivanggulati.catalyst")
        let url = appDir.appendingPathComponent("config.json")
        
        // Write garbage
        try "GARBAGE".write(to: url, atomically: true, encoding: .utf8)
        
        // Re-init (ConfigStore loads on init)
        let store = ConfigStore()
        
        // Should have reset to default
        XCTAssertTrue(store.installedPython.isEmpty)
        print("✅ ConfigStore survived corruption")
    }
    
    // MARK: - Concurrency Stress
    
    @MainActor
    func testProjectStore_ConcurrentWrites() async {
        let store = ProjectStore.shared
        // Clear first
        store.projects = []
        
        // 100 concurrent adds
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask { @MainActor in
                    let p = Project(name: "P\(i)", path: "/tmp/p\(i)", pythonVersion: "3.12")
                    store.add(p)
                }
            }
        }
        
        // Check final count (should be 100)
        let count = store.projects.count
        XCTAssertEqual(count, 100)
        print("✅ ProjectStore handled 100 concurrent writes")
    }
    
    // MARK: - ViewModel Chaos
    
    @MainActor
    func testDashboardViewModel_RapidRefresh() async {
        let logger = Logger.shared
        let privileges = PrivilegesService(logger: logger)
        let config = ConfigStore.shared
        let pythonService = PythonService(logger: logger, config: config, privileges: privileges)
        let brewService = BrewService(logger: logger, privileges: privileges)
        
        let vm = DashboardViewModel(
            brewService: brewService,
            pythonService: pythonService,
            privileges: privileges,
            logger: logger
        )
        
        // Spam refresh
        for _ in 0..<50 {
            // we don't await, we just fire and forget to simulate user mashing button
            Task {
                await vm.runDetection()
            }
        }
        
        // Wait a bit for chaos to settle
        try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
        
        // Should be alive
        XCTAssertNotNil(vm.installedPythons)
        print("✅ DashboardViewModel survived rapid refresh spam")
    }
    
    @MainActor
    func testVirtualEnvironments_InvalidPaths() async {
        let vm = VirtualEnvironmentsViewModel()
        
        // Pass a file path instead of folder
        let fileURL = URL(fileURLWithPath: "/bin/ls")
        
        // handleDrop expects NSItemProvider, we invoke internal logic if possible
        // Since we can't easily mock NSItemProvider with fileURL in a simple way without boilerplate,
        // we'll check the logic via a new test method if we exposed it, or relying on `selectFolder`.
        
        // Let's create a Project with invalid path
        let p = Project(name: "Invalid", path: "/path/that/does/not/exist/at/all/123", pythonVersion: "3.12")
        
        // VM should handle missing project
        let isMissing = vm.isProjectMissing(p)
        XCTAssertTrue(isMissing)
        
        // Remove it
        vm.deleteProject(p)
        print("✅ VirtualEnvironmentsViewModel handled invalid paths")
    }
    
    // MARK: - Legacy Cleanup Tests
    
    func testLegacyBackups_Cleanup() {
        // Simulate legacy backups exist
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let legacyFile = home.appendingPathComponent(".zshrc.catalyst.backup.20200101_000000")
        
        try? "test".write(to: legacyFile, atomically: true, encoding: .utf8)
        
        // Verify we can find them
        let files = try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
        let backups = files?.filter { $0.lastPathComponent.contains("zshrc.catalyst.backup") }
        
        XCTAssertNotNil(backups)
        XCTAssertTrue(backups!.count > 0)
        
        // We don't have a designated "Cleanup Service" yet, but testing that we CAN identify them is key
        // for future implementation.
        
        // Cleanup test artifact
        try? fm.removeItem(at: legacyFile)
    }
}
