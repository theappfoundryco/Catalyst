import SwiftUI

/// Shared Cruft Sweeper models. Moved out of `CruftSweeperViewModel` (R1 god-VM
/// decomposition) so both the ViewModel and the `CruftScanner` service can use
/// them without referencing the VM. The View previously referenced these as
/// `CruftSweeperViewModel.CruftType` / `.CruftItem`; those are now top-level.

/// A category of reclaimable build artifact.
///
/// ```swift
/// let type = CruftType.derivedData
/// print(type.safety.label) // "Safe"
/// ```
enum CruftType: String, CaseIterable, Identifiable {
    /// JavaScript dependencies restored via npm install.
    case nodeModules = "node_modules"
    /// Python virtual environments containing isolated packages.
    case venv = ".venv"
    /// Xcode intermediate build products and shared caches.
    case derivedData = "DerivedData"
    /// Compiled Python bytecode caches generated automatically.
    case cache = "__pycache__"
    /// Generic build artifacts for various build systems.
    case build = "build"
    /// Rust compiled binary output and caches.
    case target = "target" // Rust
    /// Java Gradle project caches and temporary states.
    case gradle = ".gradle" // Java/Android
    /// Java Maven build output directories.
    case mvnTarget = "mvn_target" // Java Maven
    /// Unclassified artifacts falling outside strict matching patterns.
    case unknown = "Other"

    /// The stable string identifier mapping directly to the raw directory value.
    var id: String { rawValue }

    /// The human-readable category title displayed on the section header.
    var title: String {
        switch self {
        case .nodeModules: return "Node.js"
        case .venv: return "Python venv"
        case .derivedData: return "Xcode"
        case .cache: return "Python Cache"
        case .build: return "Build Artifacts"
        case .target: return "Rust"
        case .gradle: return "Gradle (Java)"
        case .mvnTarget: return "Maven (Java)"
        case .unknown: return "Other"
        }
    }

    /// One-line description of what this target clears, for the config rows.
    var detail: String {
        switch self {
        case .nodeModules: return "node_modules in JS/TS projects"
        case .venv: return "Python virtual environments (.venv)"
        case .derivedData: return "Xcode DerivedData & shared caches"
        case .cache: return "__pycache__ bytecode caches"
        case .build: return "build/ output directories"
        case .target: return "Rust target/ directories"
        case .gradle: return "Gradle project caches (.gradle)"
        case .mvnTarget: return "Maven target/ output"
        case .unknown: return "Uncategorized items"
        }
    }

    /// The canonical SF Symbol name identifying the framework in visual lists.
    var icon: String {
        switch self {
        case .nodeModules: return "hexagon.fill"
        case .venv: return "leaf.fill"
        case .derivedData: return "hammer.fill"
        case .cache: return "memorychip"
        case .build: return "shippingbox.fill"
        case .target: return "gearshape.fill"
        case .gradle: return "building.columns.fill"
        case .mvnTarget: return "cup.and.saucer.fill"
        case .unknown: return "questionmark.folder"
        }
    }

    /// The semantic color representing the framework, mirroring the standard domain colors.
    var color: Color {
        switch self {
        case .nodeModules: return .green
        case .venv: return .yellow
        case .derivedData: return .blue
        case .cache: return .gray
        case .build: return .orange
        case .gradle: return .mint
        case .mvnTarget: return .brown
        case .target: return .red
        case .unknown: return .secondary
        }
    }

    /// How costly it is to get this artifact back after deleting it — drives the
    /// per-row safety chip and the "Select Safe" smart selection.
    enum Safety {
        /// Regenerated automatically on next use (caches, DerivedData).
        case safe
        /// Requires an explicit rebuild or reinstall to restore.
        case rebuild

        /// The concise label used for the inline chip.
        var label: String { self == .safe ? "Safe" : "Rebuild" }
        /// The color accent for the safety chip.
        var color: Color { self == .safe ? .green : .orange }
        /// Detailed explanation of the consequence of deletion, shown in tooltips.
        var detail: String {
            self == .safe
                ? "Regenerates automatically on next use — safe to clear."
                : "You'll need to rebuild or reinstall to restore this."
        }
    }

    /// The configured safety level designating how easily the artifact can be restored.
    var safety: Safety {
        switch self {
        case .cache, .derivedData: return .safe
        case .nodeModules, .venv, .build, .target, .gradle, .mvnTarget, .unknown: return .rebuild
        }
    }
}

/// A single reclaimable item found by the scan.
struct CruftItem: Identifiable, Equatable {
    /// A unique random identifier required for SwiftUI diffing logic.
    let id = UUID()
    /// The absolute file path anchor referencing the physical artifact on disk.
    let url: URL
    /// The classified category identifying the framework ownership of this artifact.
    let type: CruftType
    /// The physical byte size reported by the filesystem traversal logic.
    let size: Int64
    /// The modification timestamp used to gate deletion logic based on recency.
    let dateModified: Date

    /// A display-friendly string formatting the parent directory name with the artifact name.
    var name: String {
        // For display, show the parent so e.g. "MyApp / node_modules".
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? url.lastPathComponent : "\(parent) / \(url.lastPathComponent)"
    }

    /// The localized basename of the directory on disk.
    var simpleName: String { url.lastPathComponent }
    /// The absolute string path to the artifact.
    var path: String { url.path }
    /// The localized byte size converted to a standard file count style.
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Cruft items grouped by their location (root folder), for the grouped UI.
struct LocationGroup: Identifiable, Equatable {
    /// A unique identifier required for SwiftUI iteration.
    let id = UUID()
    /// The localized string representing the root folder encompassing the artifacts.
    let name: String
    /// The array of individual artifacts found inside this root folder.
    var items: [CruftItem]
    /// A boolean capturing the user interface disclosure state for the group.
    var isExpanded: Bool = false

    /// The cumulative physical byte size of all contained items.
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    /// The localized byte size converted to a standard file count style.
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}
