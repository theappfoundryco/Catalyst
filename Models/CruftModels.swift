import SwiftUI

/// Shared Cruft Sweeper models. Moved out of `CruftSweeperViewModel` (R1 god-VM
/// decomposition) so both the ViewModel and the `CruftScanner` service can use
/// them without referencing the VM. The View previously referenced these as
/// `CruftSweeperViewModel.CruftType` / `.CruftItem`; those are now top-level.

/// A category of reclaimable build artifact.
enum CruftType: String, CaseIterable, Identifiable {
    case nodeModules = "node_modules"
    case venv = ".venv"
    case derivedData = "DerivedData"
    case cache = "__pycache__"
    case build = "build"
    case target = "target" // Rust
    case gradle = ".gradle" // Java/Android
    case mvnTarget = "mvn_target" // Java Maven
    case unknown = "Other"

    var id: String { rawValue }

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

        var label: String { self == .safe ? "Safe" : "Rebuild" }
        var color: Color { self == .safe ? .green : .orange }
        var detail: String {
            self == .safe
                ? "Regenerates automatically on next use — safe to clear."
                : "You'll need to rebuild or reinstall to restore this."
        }
    }

    var safety: Safety {
        switch self {
        case .cache, .derivedData: return .safe
        case .nodeModules, .venv, .build, .target, .gradle, .mvnTarget, .unknown: return .rebuild
        }
    }
}

/// A single reclaimable item found by the scan.
struct CruftItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let type: CruftType
    let size: Int64
    let dateModified: Date

    var name: String {
        // For display, show the parent so e.g. "MyApp / node_modules".
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? url.lastPathComponent : "\(parent) / \(url.lastPathComponent)"
    }

    var simpleName: String { url.lastPathComponent }
    var path: String { url.path }
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Cruft items grouped by their location (root folder), for the grouped UI.
struct LocationGroup: Identifiable, Equatable {
    let id = UUID()
    let name: String
    var items: [CruftItem]
    var isExpanded: Bool = false

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}
