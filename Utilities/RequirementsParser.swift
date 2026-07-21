import Foundation

/// Pure parsing of `requirements.txt` package names plus PEP 503 name
/// normalization. Extracted from `VirtualEnvCreationViewModel` (R1) so the logic
/// is testable in isolation and reusable by the verifier.
enum RequirementsParser {

    /// Normalized package names from a `requirements.txt` body. Skips
    /// comment/blank/option/URL/VCS lines and strips inline comments, environment
    /// markers, extras, and version specifiers.
    static func names(from contents: String) -> [String] {
        contents.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty
                && !line.hasPrefix("#")
                && !line.hasPrefix("-")       // -r, -e, options
                && !line.hasPrefix("http")
                && !line.hasPrefix("git+")
            }
            .compactMap { line -> String? in
                var s = line
                if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }        // inline comment
                if let semi = s.firstIndex(of: ";") { s = String(s[..<semi]) }        // env marker
                if let bracket = s.firstIndex(of: "[") { s = String(s[..<bracket]) }  // extras
                let base = s.components(separatedBy: CharacterSet(charactersIn: "=<>!~")).first ?? s
                let name = base.trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : normalize(name)
            }
    }

    /// PEP 503-style normalization: lowercase and replace `_`/`.` with `-`.
    static func normalize(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
}
