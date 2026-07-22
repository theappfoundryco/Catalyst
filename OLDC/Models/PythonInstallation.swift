import Foundation

/// A data model characterizing a recognized local Python runtime environment mapped to the dependency chain.
struct PythonInstallation: Identifiable, Hashable, Sendable {
    /// A unique random identification token necessary for SwiftUI interface layers.
    let id = UUID()
    /// The parsed semantic version array mapping to this explicit hardware footprint.
    let version: String
    /// The localized absolute terminal path navigating directly to the binary instance.
    let path: URL
    /// A diagnostic boolean indicating the availability of the `pip` ecosystem module.
    let pipAvailable: Bool
    /// The parsed semantic version array specifying module limitations if active.
    let pipVersion: String?
    /// The mapped string configuration connecting equivalent Homebrew packages logically.
    let formula: String
    
    /// Hashes the essential components into the provided hasher.
    ///
    /// - Parameter hasher: The hasher to use when combining the components of this instance.
    func hash(into hasher: inout Hasher) {
        hasher.combine(version)
        hasher.combine(path)
    }
    
    /// Computes equity between active runtime logic nodes.
    ///
    /// - Parameters:
    ///   - lhs: The logical instance occupying the left block.
    ///   - rhs: The logical instance occupying the right block.
    /// - Returns: A boolean validating strict configuration mapping equity.
    static func == (lhs: PythonInstallation, rhs: PythonInstallation) -> Bool {
        lhs.version == rhs.version && lhs.path == rhs.path
    }
}
