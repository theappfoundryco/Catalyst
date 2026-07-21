import Foundation

/// An overarching utility for comparing semantic version strings algebraically.
///
/// `VersionComparator` centralizes version constraint enforcement logic required to map correctly
/// against different Homebrew or Python versioning schemes.
enum VersionComparator {
    
    /// Compares two normalized version strings sequentially through their semantic segments.
    ///
    /// - Parameters:
    ///   - v1: The first version string literal.
    ///   - v2: The second version string literal.
    /// - Returns: A negative integer if `v1` is older, zero if equal, and positive if `v1` is newer.
    static func compare(_ v1: String, _ v2: String) -> Int {
        let trimSet = CharacterSet.whitespacesAndNewlines
        let v1Clean = v1.trimmingCharacters(in: trimSet)
        let v2Clean = v2.trimmingCharacters(in: trimSet)
        
        func parseParts(_ v: String) -> [Int] {
            var parts: [Int] = []
            let components = v.split(separator: ".")
            for component in components {
                if let val = Int(component) {
                    parts.append(val)
                } else {
                    let digits = component.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map { String($0) }.joined()
                    parts.append(Int(digits) ?? 0)
                }
            }
            return parts
        }
        
        let parts1 = parseParts(v1Clean)
        let parts2 = parseParts(v2Clean)
        
        let count = max(parts1.count, parts2.count)
        
        for i in 0..<count {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            
            if p1 < p2 { return -1 }
            if p1 > p2 { return 1 }
        }
        
        return 0
    }
    
    /// Validates if the first version input operates as a newer iteration than the baseline parameter.
    ///
    /// - Parameters:
    ///   - v1: The target version string being analyzed.
    ///   - v2: The baseline version string defining the comparative metric.
    /// - Returns: A Boolean asserting if `v1` represents a newer version iteration.
    static func isNewer(_ v1: String, than v2: String) -> Bool {
        return compare(v1, v2) > 0
    }
    
    /// Validates if the first version operates as an older iteration than the baseline parameter.
    ///
    /// - Parameters:
    ///   - v1: The target version string being analyzed.
    ///   - v2: The baseline version string defining the comparative metric.
    /// - Returns: A Boolean asserting if `v1` represents an older version iteration.
    static func isOlder(_ v1: String, than v2: String) -> Bool {
        return compare(v1, v2) < 0
    }
    
    /// Determines whether a specified Python version mandates specific system flags to install packages.
    ///
    /// - Parameter pythonVersion: The semantic Python identifier executing the package load structure.
    /// - Returns: A Boolean indicating if `--break-system-packages` is required for global operations.
    static func requiresBreakSystemPackages(pythonVersion: String) -> Bool {
        let parts = pythonVersion.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return parts[0] > 3 || (parts[0] == 3 && parts[1] >= 12)
    }
    
    /// Iterates through an unsorted version string array and returns a chronologically ascending stack.
    ///
    /// - Parameter versions: The unsorted compilation of version strings.
    /// - Returns: An array of version strings sorted from oldest to newest.
    static func sortedAscending(_ versions: [String]) -> [String] {
        return versions.sorted { compare($0, $1) < 0 }
    }
    
    /// Iterates through an unsorted version string array and returns a chronologically descending stack.
    ///
    /// - Parameter versions: The unsorted compilation of version strings.
    /// - Returns: An array of version strings sorted from newest to oldest.
    static func sortedDescending(_ versions: [String]) -> [String] {
        return versions.sorted { compare($0, $1) > 0 }
    }
}
