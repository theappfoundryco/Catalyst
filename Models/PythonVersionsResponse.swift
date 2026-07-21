import Foundation

/// A Python version installable via Homebrew (`python@<version>`), discovered **live from
/// `brew`** rather than a backend `python_versions.json` (removed 2026-07). `deprecated`
/// mirrors the Homebrew formula's deprecation status so the UI can flag it.
struct AvailableVersion: Identifiable, Equatable, Hashable {
    var id: String { version }
    let version: String     // "3.13" (major.minor → the formula `python@3.13`)
    let deprecated: Bool
}
