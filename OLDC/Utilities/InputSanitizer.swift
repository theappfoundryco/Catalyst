import Foundation

/// A security utility for sanitizing and validating inputs before they are evaluated in shell contexts.
///
/// `InputSanitizer` guards against command injection via package names, paths, or function aliases.
/// Validation for user-entered BILLING fields.
///
/// Extracted rather than written per-view-model on purpose (Formrules 12.27): the venv-name
/// rule already proved that a validation rule living inside one VM gets copy-pasted and then
/// drifts. Every function here returns an inline reason string (nil = valid) so the UI can show
/// *why* a field is rejected instead of silently disabling the button.
///
/// These are FORMAT checks, not truth checks. A syntactically valid address can still be wrong,
/// which is exactly why the form warns the user to double-check before paying.
enum BillingValidators {

    /// Trim once, in one place — every rule below assumes already-trimmed input.
    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func name(_ raw: String) -> String? {
        let v = clean(raw)
        if v.isEmpty { return "Enter the name this invoice should be made out to." }
        if v.count < 2 { return "That looks too short to be a name." }
        if v.count > 100 { return "Keep this under 100 characters." }
        return nil
    }

    /// Deliberately permissive: one `@`, something either side, a dot in the domain. Stricter
    /// regexes reject real addresses (plus-tags, new TLDs, long subdomains) and the cost of a
    /// false rejection here is a user who cannot buy.
    static func email(_ raw: String) -> String? {
        let v = clean(raw)
        if v.isEmpty { return "Enter an email address for the invoice." }
        if v.count > 254 { return "That email address is too long." }
        let parts = v.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !v.contains(" ") else { return "That doesn't look like a valid email address." }
        return nil
    }

    /// REQUIRED. Digits, spaces, +, -, ( ) only; 7–15 digits (E.164 max).
    ///
    /// Not a legal requirement on a non-GST invoice — a product decision, so that support has a
    /// second way to reach a buyer when an email bounces.
    static func phone(_ raw: String) -> String? {
        let v = clean(raw)
        if v.isEmpty { return "Enter a phone number." }
        let digits = v.filter(\.isNumber)
        if digits.count < 7 || digits.count > 15 { return "Enter a valid phone number." }
        if v.contains(where: { !($0.isNumber || " +-()".contains($0)) }) {
            return "Phone numbers can only contain digits, spaces, +, - and brackets."
        }
        return nil
    }

    static func line1(_ raw: String) -> String? {
        let v = clean(raw)
        if v.isEmpty { return "Enter a street address." }
        if v.count > 200 { return "Keep this under 200 characters." }
        return nil
    }

    static func city(_ raw: String) -> String? {
        let v = clean(raw)
        if v.isEmpty { return "Enter a city." }
        if v.count > 100 { return "Keep this under 100 characters." }
        return nil
    }

    /// Postal codes vary wildly by country, so the only universal rules are non-empty and
    /// alphanumeric-ish. India gets the one extra rule worth enforcing (6 digits) because
    /// that's the market actually being sold to today.
    static func postalCode(_ raw: String, country: String) -> String? {
        let v = clean(raw)
        if v.isEmpty { return "Enter a postal code." }
        if v.count > 16 { return "That postal code is too long." }
        if country.uppercased() == "IN" {
            let digits = v.filter(\.isNumber)
            if digits.count != 6 || digits.count != v.count { return "Indian PIN codes are 6 digits." }
        }
        return nil
    }

    static func country(_ raw: String) -> String? {
        let v = clean(raw).uppercased()
        if v.count != 2 || v.contains(where: { !$0.isLetter }) { return "Select a country." }
        return nil
    }

    /// Gift codes are stored uppercase and unpunctuated; normalise before validating so a
    /// pasted `catl-2026-abcd` is judged as `CATL2026ABCD` — the same thing the server compares.
    static func normalizeGiftCode(_ raw: String) -> String {
        raw.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    static func giftCode(_ raw: String) -> String? {
        let v = normalizeGiftCode(raw)
        if v.isEmpty { return "Enter a code." }
        if v.count < 6 || v.count > 32 { return "That doesn't look like a valid code." }
        return nil
    }
}

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