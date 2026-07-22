import XCTest
@testable import Catalyst

/// Comprehensive Model Tests
/// Tests all model structs for proper initialization and behavior
final class ModelTests: XCTestCase {
    
    // MARK: - PythonInstallation Tests
    
    func testPythonInstallation_Initialization() {
        let installation = PythonInstallation(
            version: "3.12.1",
            path: URL(fileURLWithPath: "/opt/homebrew/bin/python3.12"),
            pipAvailable: true,
            pipVersion: "24.0",
            formula: "python@3.12"
        )
        
        XCTAssertEqual(installation.version, "3.12.1")
        XCTAssertEqual(installation.path.lastPathComponent, "python3.12")
        XCTAssertTrue(installation.pipAvailable)
        XCTAssertEqual(installation.pipVersion, "24.0")
        XCTAssertEqual(installation.formula, "python@3.12")
    }
    
    func testPythonInstallation_NoPip() {
        let installation = PythonInstallation(
            version: "3.11.0",
            path: URL(fileURLWithPath: "/usr/bin/python3"),
            pipAvailable: false,
            pipVersion: nil,
            formula: "python@3.11"
        )
        
        XCTAssertFalse(installation.pipAvailable)
        XCTAssertNil(installation.pipVersion)
    }
    
    func testPythonInstallation_Equatable() {
        let install1 = PythonInstallation(
            version: "3.12.1",
            path: URL(fileURLWithPath: "/opt/homebrew/bin/python3.12"),
            pipAvailable: true,
            pipVersion: "24.0",
            formula: "python@3.12"
        )
        
        let install2 = PythonInstallation(
            version: "3.12.1",
            path: URL(fileURLWithPath: "/opt/homebrew/bin/python3.12"),
            pipAvailable: false, // Different pip status
            pipVersion: nil,
            formula: "python@3.12"
        )
        
        // Should be equal based on version and path only
        XCTAssertEqual(install1, install2)
    }
    
    func testPythonInstallation_Hashable() {
        let install1 = PythonInstallation(
            version: "3.12.1",
            path: URL(fileURLWithPath: "/opt/homebrew/bin/python3.12"),
            pipAvailable: true,
            pipVersion: "24.0",
            formula: "python@3.12"
        )
        
        let install2 = PythonInstallation(
            version: "3.12.1",
            path: URL(fileURLWithPath: "/opt/homebrew/bin/python3.12"),
            pipAvailable: true,
            pipVersion: "24.0",
            formula: "python@3.12"
        )
        
        var set = Set<PythonInstallation>()
        set.insert(install1)
        set.insert(install2)
        
        XCTAssertEqual(set.count, 1) // Should dedupe
    }
    
    // MARK: - AliasItem Tests
    
    func testAliasItem_Initialization() {
        let alias = AliasItem(
            name: "gs",
            command: "git status",
            isCatalystManaged: true
        )
        
        XCTAssertEqual(alias.name, "gs")
        XCTAssertEqual(alias.command, "git status")
        XCTAssertTrue(alias.isCatalystManaged)
    }
    
    func testAliasItem_DefaultNotManaged() {
        let alias = AliasItem(name: "ll", command: "ls -la")
        
        XCTAssertFalse(alias.isCatalystManaged)
    }
    
    func testAliasItem_Identifiable() {
        let alias1 = AliasItem(name: "gs", command: "git status")
        let alias2 = AliasItem(name: "gs", command: "git status")
        
        // Each should have unique ID
        XCTAssertNotEqual(alias1.id, alias2.id)
    }
    
    // MARK: - PackageType Tests
    
    func testPackageType_AllCases() {
        let allCases = PackageType.allCases
        
        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.pip))
        XCTAssertTrue(allCases.contains(.brewFormula))
        XCTAssertTrue(allCases.contains(.brewCask))
    }
    
    func testPackageType_DisplayNames() {
        XCTAssertEqual(PackageType.pip.displayName, "pip")
        XCTAssertEqual(PackageType.brewFormula.displayName, "Homebrew Formula")
        XCTAssertEqual(PackageType.brewCask.displayName, "Homebrew Cask")
    }
    
    func testPackageType_ShortNames() {
        XCTAssertEqual(PackageType.pip.shortName, "pip")
        XCTAssertEqual(PackageType.brewFormula.shortName, "brew")
        XCTAssertEqual(PackageType.brewCask.shortName, "cask")
    }
    
    func testPackageType_Icons() {
        XCTAssertFalse(PackageType.pip.iconName.isEmpty)
        XCTAssertFalse(PackageType.brewFormula.iconName.isEmpty)
        XCTAssertFalse(PackageType.brewCask.iconName.isEmpty)
    }
    
    func testPackageType_Emojis() {
        XCTAssertEqual(PackageType.pip.emoji, "🐍")
        XCTAssertEqual(PackageType.brewFormula.emoji, "🍺")
        XCTAssertEqual(PackageType.brewCask.emoji, "🍺")
    }
    
    func testPackageType_RawValues() {
        XCTAssertEqual(PackageType.pip.rawValue, "pip")
        XCTAssertEqual(PackageType.brewFormula.rawValue, "brewFormula")
        XCTAssertEqual(PackageType.brewCask.rawValue, "brewCask")
    }
    
    // MARK: - SmartShortcuts Models Tests
    
    func testShortcutItem_Decoding() throws {
        let json = """
        {
            "id": "git-status",
            "category": "Git",
            "title": "Git Status",
            "tagline": "Check repo status",
            "icon": "arrow.triangle.branch",
            "color": "orange",
            "version": "1.0",
            "date_added": "2024-01-01"
        }
        """
        
        let data = json.data(using: .utf8)!
        let item = try JSONDecoder().decode(ShortcutItem.self, from: data)
        
        XCTAssertEqual(item.id, "git-status")
        XCTAssertEqual(item.category, "Git")
        XCTAssertEqual(item.title, "Git Status")
        XCTAssertEqual(item.version, "1.0")
    }
    
    func testShortcutDependencies_Decoding() throws {
        let json = """
        {
            "brew": ["git", "curl"],
            "pip": ["requests", "numpy"]
        }
        """
        
        let data = json.data(using: .utf8)!
        let deps = try JSONDecoder().decode(ShortcutDependencies.self, from: data)
        
        XCTAssertEqual(deps.brew.count, 2)
        XCTAssertEqual(deps.pip.count, 2)
        XCTAssertTrue(deps.brew.contains("git"))
        XCTAssertTrue(deps.pip.contains("numpy"))
    }
    
    func testInstalledShortcut_Decoding() throws {
        let json = """
        {
            "id": "git-status",
            "custom_name": "gs",
            "installed_at": "2024-01-15T10:30:00Z",
            "version": "1.0"
        }
        """
        
        let data = json.data(using: .utf8)!
        let installed = try JSONDecoder().decode(InstalledShortcut.self, from: data)
        
        XCTAssertEqual(installed.id, "git-status")
        XCTAssertEqual(installed.custom_name, "gs")
        XCTAssertEqual(installed.version, "1.0")
    }
    
    func testShortcutItem_CategoryColor() throws {
        let gitItem = shortcutItem(category: "Git")
        let systemItem = shortcutItem(category: "System")
        let networkItem = shortcutItem(category: "Network")
        let unknownItem = shortcutItem(category: "Unknown")
        
        XCTAssertEqual(gitItem.categoryColor, "orange")
        XCTAssertEqual(systemItem.categoryColor, "blue")
        XCTAssertEqual(networkItem.categoryColor, "green")
        XCTAssertEqual(unknownItem.categoryColor, "gray")
    }
    
    // Helper to create test ShortcutItem
    private func shortcutItem(category: String) -> ShortcutItem {
        return ShortcutItem(
            id: "test",
            category: category,
            title: "Test",
            tagline: "Test",
            icon: "star",
            color: "blue",
            version: "1.0",
            date_added: "2024-01-01"
        )
    }
}

/// Network Configuration Tests

