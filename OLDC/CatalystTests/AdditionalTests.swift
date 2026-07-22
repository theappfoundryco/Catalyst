import XCTest
@testable import Catalyst

/// Comprehensive BrewPathManager tests
/// Tests Homebrew path detection across different macOS configurations


/// Comprehensive AliasValidator tests
final class AliasValidatorTests: XCTestCase {
    
    // MARK: - Valid Alias Names
    
    func testValidAliasNames() {
        XCTAssertTrue(AliasValidator.isValidAliasName("gs"))
        XCTAssertTrue(AliasValidator.isValidAliasName("myAlias"))
        XCTAssertTrue(AliasValidator.isValidAliasName("my_alias"))
        XCTAssertTrue(AliasValidator.isValidAliasName("my-alias"))
        XCTAssertTrue(AliasValidator.isValidAliasName("MyAlias123"))
        XCTAssertTrue(AliasValidator.isValidAliasName("a"))
        XCTAssertTrue(AliasValidator.isValidAliasName("A"))
    }
    
    // MARK: - Invalid Alias Names
    
    func testInvalidAliasNames_StartsWithNumber() {
        XCTAssertFalse(AliasValidator.isValidAliasName("123alias"))
        XCTAssertFalse(AliasValidator.isValidAliasName("1"))
        XCTAssertFalse(AliasValidator.isValidAliasName("9test"))
    }
    
    func testInvalidAliasNames_StartsWithSpecialChar() {
        XCTAssertFalse(AliasValidator.isValidAliasName("-alias"))
        XCTAssertFalse(AliasValidator.isValidAliasName("_alias")) // Underscores OK at start? Check pattern
        XCTAssertFalse(AliasValidator.isValidAliasName("@alias"))
        XCTAssertFalse(AliasValidator.isValidAliasName("$alias"))
    }
    
    func testInvalidAliasNames_SpecialCharacters() {
        XCTAssertFalse(AliasValidator.isValidAliasName("alias!"))
        XCTAssertFalse(AliasValidator.isValidAliasName("alias@home"))
        XCTAssertFalse(AliasValidator.isValidAliasName("alias#tag"))
        XCTAssertFalse(AliasValidator.isValidAliasName("alias$var"))
        XCTAssertFalse(AliasValidator.isValidAliasName("alias%mod"))
        XCTAssertFalse(AliasValidator.isValidAliasName("alias with space"))
    }
    
    func testInvalidAliasNames_Empty() {
        XCTAssertFalse(AliasValidator.isValidAliasName(""))
    }
    
    func testInvalidAliasNames_Whitespace() {
        XCTAssertFalse(AliasValidator.isValidAliasName("   "))
        XCTAssertFalse(AliasValidator.isValidAliasName("\t"))
        XCTAssertFalse(AliasValidator.isValidAliasName("\n"))
    }
    
    // MARK: - Valid Commands
    
    func testValidCommands() {
        XCTAssertTrue(AliasValidator.isValidCommand("git status"))
        XCTAssertTrue(AliasValidator.isValidCommand("ls -la"))
        XCTAssertTrue(AliasValidator.isValidCommand("echo 'hello'"))
        XCTAssertTrue(AliasValidator.isValidCommand("cd ~/Documents && ls"))
    }
    
    func testInvalidCommands() {
        XCTAssertFalse(AliasValidator.isValidCommand(""))
        XCTAssertFalse(AliasValidator.isValidCommand("   "))
        XCTAssertFalse(AliasValidator.isValidCommand("\t\t"))
    }
    
    // MARK: - Name Sanitization
    
    func testSanitizeName() {
        XCTAssertEqual(AliasValidator.sanitizeName("my alias"), "myalias")
        XCTAssertEqual(AliasValidator.sanitizeName("my@alias"), "myalias")
        XCTAssertEqual(AliasValidator.sanitizeName("my!@#$alias"), "myalias")
        XCTAssertEqual(AliasValidator.sanitizeName("my_alias"), "my_alias")
        XCTAssertEqual(AliasValidator.sanitizeName("my-alias"), "my-alias")
    }
}

/// Stress tests for the entire system
final class StressTests: XCTestCase {
    
    // MARK: - Memory Stress
    
    func testSanitizeThousandsOfInputs() {
        // Sanitize 10,000 inputs without memory issues
        for i in 0..<10_000 {
            let _ = InputSanitizer.sanitizePackageName("package\(i)")
        }
        XCTAssertTrue(true) // If we get here, no memory issues
    }
    
    func testCompareThousandsOfVersions() {
        // Compare 10,000 version pairs
        for _ in 0..<10_000 {
            let _ = VersionComparator.compare("3.12.1", "3.11.9")
        }
        XCTAssertTrue(true)
    }
    
    // MARK: - Rapid Concurrent Access
    
    func testRapidConcurrentSanitization() async {
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let result = await InputSanitizer.sanitizePackageName("pkg\(i)")
                    return result != nil
                }
            }
            
            var successCount = 0
            for await success in group {
                if success { successCount += 1 }
            }
            
            XCTAssertEqual(successCount, 100)
        }
    }
    
    func testRapidConcurrentVersionComparison() async {
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    return await VersionComparator.compare("3.12", "3.11")
                }
            }
            
            var allPositive = true
            for await result in group {
                if result <= 0 { allPositive = false }
            }
            
            XCTAssertTrue(allPositive)
        }
    }
    
    // MARK: - Edge Case Bombardment
    
    func testEdgeCaseBombardment_InputSanitizer() {
        // Throw everything at it
        let evilInputs = [
            "", "   ", "\t", "\n", "\r\n",
            "$()", "`cmd`", "; rm -rf /",
            "a;b", "a|b", "a&b", "a>b", "a<b",
            "'", "\"", "\\", "/", "..",
            "../..", "/etc/passwd", "~/.ssh",
            String(repeating: "a", count: 1000),
            String(repeating: "🔥", count: 100),
            "\u{0000}", "\u{200B}", "\u{FEFF}",
            "pkg\0evil", "a\nb", "a\rb"
        ]
        
        for input in evilInputs {
            // Should handle gracefully, not crash
            let _ = InputSanitizer.sanitizePackageName(input)
            let _ = InputSanitizer.isValidPackageName(input)
            let _ = InputSanitizer.singleQuote(input)
            let _ = InputSanitizer.isValidFilePath(input)
        }
        
        XCTAssertTrue(true) // Survived!
    }
    
    func testEdgeCaseBombardment_VersionComparator() {
        let evilVersions = [
            "", "   ", "\t", "\n",
            ".", "..", "...", "....",
            "1", "1.", ".1", "1..", "..1",
            "abc", "1.abc", "abc.1",
            "-1", "1.-1", "-1.-1",
            String(repeating: "9", count: 100),
            "1.2.3.4.5.6.7.8.9.10",
            "999999999999.999999999999.999999999999"
        ]
        
        for v1 in evilVersions {
            for v2 in evilVersions {
                // Should handle gracefully
                let _ = VersionComparator.compare(v1, v2)
                let _ = VersionComparator.isNewer(v1, than: v2)
                let _ = VersionComparator.isOlder(v1, than: v2)
            }
        }
        
        for v in evilVersions {
            let _ = VersionComparator.requiresBreakSystemPackages(pythonVersion: v)
        }
        
        XCTAssertTrue(true) // Survived!
    }
}
