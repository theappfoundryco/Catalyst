import Foundation

/// A Python version installable via Homebrew (`python@<version>`), discovered **live from
/// `brew`** rather than a backend `python_versions.json` (removed 2026-07). `deprecated`
/// mirrors the Homebrew formula's deprecation status so the UI can flag it.
struct AvailableVersion: Identifiable, Equatable, Hashable {
    /// A string identifier bound exactly to the semantic version string.
    var id: String { version }
    /// The major and minor version block, configuring the corresponding Homebrew package formula (e.g. `python@3.13`).
    let version: String     // "3.13" (major.minor → the formula `python@3.13`)
    /// A boolean mirroring the upstream Homebrew formula deprecation state, used for rendering interface warnings.
    let deprecated: Bool
}
