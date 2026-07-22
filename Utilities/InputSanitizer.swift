import Foundation

/// A security utility for sanitizing and validating inputs before they are evaluated in shell contexts.
///
/// `InputSanitizer` guards against command injection via package names, paths, or function aliases.
///
/// ```swift
/// let safeName = InputSanitizer.sanitizePackageName("requests")
/// ```
enum InputSanitizer {

    private static let validPackageNamePattern = "^[a-zA-Z0-9][a-zA-Z0-9._@-]*$"
    
    /// Validates and sanitizes a package name for safe shell usage.
    ///
    /// - Parameter name: The package name to process.
    /// - Returns: The sanitized standard package name, or `nil` if the pattern contains dangerous characters.
    static func sanitizePackageName(_ name: String) -> String? {
        if name.contains(where: { $0.isNewline || $0.asciiValue == nil && !$0.isLetter && !$0.isNumber }) {
            return nil
        }
        
        if !name.allSatisfy({ $0.isASCII }) {
            return nil
        }
        
        if name.unicodeScalars.contains(where: { 
            CharacterSet.controlCharacters.contains($0) ||
            $0.value == 0x200B ||
            $0.value == 0x00AD ||
            $0.value == 0xFEFF
        }) {
            return nil
        }
        
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmed.isEmpty,
              trimmed.count <= 200,
              trimmed.range(of: validPackageNamePattern, options: .regularExpression) != nil else {
            return nil
        }
        
        return trimmed
    }
    
    /// Validates whether a package name conforms to secure character criteria.
    ///
    /// - Parameter name: The package name to validate.
    /// - Returns: A Boolean defining if the input is allowed.
    static func isValidPackageName(_ name: String) -> Bool {
        return sanitizePackageName(name) != nil
    }
    
    /// Escapes single quotes so a string is safe **only when wrapped in single
    /// quotes** (`'...'`). Private on purpose: every caller must go through
    /// `singleQuote(_:)` (which does the wrapping) or, better, the array-args
    /// path `AsyncProcessRunner.run(executable:arguments:)` which avoids the
    /// shell — and therefore quoting — entirely. This prevents the recurring
    /// "used bare / inside double quotes" class of bug.
    /// - Parameter string: The raw untrusted input payload.
    /// - Returns: A safe, single-quoted representation capable of bypassing shell expansions.
    private static func shellEscape(_ string: String) -> String {
        return string.replacingOccurrences(of: "'", with: "'\\''")
    }
    
    /// Wraps a string in single quotes after successfully escaping internal quotes.
    ///
    /// - Parameter string: The string to be quoted.
    /// - Returns: A fully escaped and quoted string.
    static func singleQuote(_ string: String) -> String {
        return "'\(shellEscape(string))'"
    }
    
    /// Sanitizes and escapes a file path string for command execution.
    ///
    /// - Parameter path: The raw file path string.
    /// - Returns: A fully sanitized, escaped, and quoted string representing the file path.
    static func sanitizeFilePath(_ path: String) -> String {
        return singleQuote(path)
    }
    
    /// Validates whether a file path avoids disallowed shell character structures.
    ///
    /// - Parameter path: The file path to validate.
    /// - Returns: A Boolean indicating if the path adheres to security specifications.
    static func isValidFilePath(_ path: String) -> Bool {
        return validateSafePath(path)
    }

    /// Evaluates if a file path is guarded against directory traversal and command boundary circumvention.
    ///
    /// - Parameter path: The target path.
    /// - Returns: A Boolean proving safety against typical string injections.
    static func validateSafePath(_ path: String) -> Bool {
        if path.contains("\0") { return false }
        
        let dangerousPatterns = [";", "|", "&", "$", "`", "\n", "\r", "(", ")", "<", ">"]
        for pattern in dangerousPatterns {
            if path.contains(pattern) { return false }
        }
        
        if path.contains("../") || path.contains("..\\") {
            return false
        }
        
        return true
    }

    /// Extends allowable path constraints for Python virtual environments.
    ///
    /// - Parameter path: The directory path for evaluation.
    /// - Returns: A Boolean asserting if the environment path is acceptable.
    static func isValidVenvPath(_ path: String) -> Bool {
        if path.contains("\0") { return false }
        
        let dangerousPatterns = [";", "|", "&", "$", "`", "\n", "\r", "<", ">"]
        for pattern in dangerousPatterns {
            if path.contains(pattern) { return false }
        }
        
        if path.contains("../") || path.contains("..\\") {
            return false
        }
        
        return true
    }
    
    private static let validFunctionNamePattern = "^[a-zA-Z_][a-zA-Z0-9_-]*$"
    
    /// Verifies if a shell function alias uses compatible POSIX characters.
    ///
    /// - Parameter name: The candidate name.
    /// - Returns: A Boolean affirming syntactic correctness.
    static func isValidFunctionName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 100,
              trimmed.range(of: validFunctionNamePattern, options: .regularExpression) != nil else {
            return false
        }
        return true
    }
    
    /// Normalizes Python package identfiers corresponding to PEP 503 standards.
    ///
    /// - Parameter name: The raw package identifier.
    /// - Returns: The collapsed standardized version.
    static func normalizePipPackageName(_ name: String) -> String {
        var normalized = name.lowercased()
        normalized = normalized.replacingOccurrences(of: "_", with: "-")
        normalized = normalized.replacingOccurrences(of: ".", with: "-")
        
        while normalized.contains("--") {
            normalized = normalized.replacingOccurrences(of: "--", with: "-")
        }
        
        return normalized
    }
}