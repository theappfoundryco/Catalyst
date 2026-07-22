import Foundation

/// A data model representing a software package to be rendered within the UI.
///
/// ```swift
/// let item = PackageItem(name: "requests", description: "Python HTTP for Humans", isInstalled: true)
/// ```
struct PackageItem: Identifiable {
    /// A unique identifier for the package instance.
    let id = UUID()
    /// The exact registered name of the package.
    let name: String
    /// An optional summary or description detailing the package's purpose.
    let description: String?
    /// A boolean indicating whether the package is currently installed system-wide.
    var isInstalled: Bool
    /// A boolean representing if an installation or removal task is currently in progress.
    var isProcessing: Bool = false
}

/// Enumerates the categories of packages managed by Homebrew.
enum BrewPackageTypeEnum {
    /// Represents a standard command-line utility or formula.
    case formula
    /// Represents a macOS graphical application distributed via Cask.
    case cask
}
