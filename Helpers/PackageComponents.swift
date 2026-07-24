/// Shared package row components used across list and search views.

import SwiftUI

// MARK: - Installed Package Row

/// A row displaying an installed package with its version and an Uninstall button.
///
/// Uses alternating row backgrounds for visual distinction in lists.
///
/// ## Usage
///
/// ```swift
/// InstalledPackageRow(
///     name: "numpy",
///     version: "1.24.0",
///     isAlternate: index % 2 == 1,
///     isProcessing: vm.uninstallingPackage == "numpy",
///     onUninstall: { vm.uninstall("numpy") }
/// )
/// ```
struct InstalledPackageRow: View, Equatable {
    /// The package name.
    let name: String
    
    /// The installed version string, if available.
    let version: String?
    
    /// Whether to use the alternate row background color.
    let isAlternate: Bool
    
    /// Whether an uninstall operation is in progress for this package.
    let isProcessing: Bool
    
    /// Called when the Uninstall button is tapped.
    let onUninstall: () -> Void

    /// R1-row: compare only the value inputs (closure ignored) so the row skips
    /// body when an unrelated @Published on the parent VM changes.
    ///
    /// **Gotchas:** Including closures in `Equatable` compliance forces SwiftUI to re-render the row on every parent state change, tanking scrolling performance on large lists.
    static func == (lhs: InstalledPackageRow, rhs: InstalledPackageRow) -> Bool {
        lhs.name == rhs.name &&
        lhs.version == rhs.version &&
        lhs.isAlternate == rhs.isAlternate &&
        lhs.isProcessing == rhs.isProcessing
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                
                if let version = version {
                    Text(version)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if isProcessing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    onUninstall()
                } label: {
                    Text(isProcessing ? "Uninstalling..." : "Uninstall")
                }
                .appButton(.destructive)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isAlternate ? Color(NSColor.controlAlternatingRowBackgroundColors[1]) : Color(NSColor.controlBackgroundColor))
    }
    
    // MARK: - Search Result Row
    
    /// A row displaying a search result with an Install button or an "Installed" label.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// InstalledPackageRow.SearchResultRow(
    ///     name: "requests",
    ///     isInstalled: false,
    ///     isAlternate: index % 2 == 1,
    ///     isProcessing: false,
    ///     onInstall: { vm.install("requests") }
    /// )
    /// ```
    struct SearchResultRow: View {
        /// The package name.
        let name: String
        
        /// Whether this package is already installed.
        let isInstalled: Bool
        
        /// Whether to use the alternate row background color.
        let isAlternate: Bool
        
        /// Whether an install operation is in progress for this package.
        let isProcessing: Bool
        
        /// Called when the Install button is tapped.
        let onInstall: () -> Void
        
        var body: some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.body)
                            .foregroundColor(isInstalled ? .secondary : .primary)
                        
                        if isInstalled {
                            Text("(Installed)")
                                .font(.caption)
                                .italic()
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else if !isInstalled {
                    Button {
                        onInstall()
                    } label: {
                        Text(isProcessing ? "Installing..." : "Install")
                    }
                    .appButton(.primary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isAlternate ? Color(NSColor.controlAlternatingRowBackgroundColors[1]) : Color(NSColor.controlBackgroundColor))
            .opacity(isInstalled ? 0.6 : 1.0)
        }
    }
}

// MARK: - Installable Package Row

/// A row for search results that can be installed (pip packages, Homebrew formulae, or casks).
///
/// Displays the package name, an "Installed" badge if already installed,
/// a spinner while installing, an install button — or a passive "Protected Mode"
/// badge when ``isProtectedMode`` is `true` (see below).
///
/// ## Usage
///
/// ```swift
/// InstallablePackageRow(
///     name: "numpy",
///     isAlternate: index % 2 == 1,
///     isInstalling: vm.installingPackage == "numpy",
///     isInstalled: vm.installedPackages.contains("numpy"),
///     canInstall: vm.isPythonAvailable,
///     isProtectedMode: prefs.mode == .protected && vm.requiresBreakSystemPackages,
///     onInstall: { Task { await vm.install("numpy") } }
/// )
/// ```
///
/// - Important: `isProtectedMode` defaults to `false` so Homebrew call sites
///   (formulae/casks, where PEP 668 does not apply) compile and behave unchanged.
///   Only pip call sites should compute it.
struct InstallablePackageRow: View {
    /// The package name.
    let name: String

    /// Whether to use the alternate row background color.
    let isAlternate: Bool

    /// Whether an install operation is in progress for this package.
    let isInstalling: Bool

    /// Whether this package is already installed.
    let isInstalled: Bool

    /// Whether the prerequisite tool is available for installation.
    let canInstall: Bool

    /// Whether installs are blocked by PEP 668 Protected mode.
    ///
    /// `true` when the selected interpreter is externally managed (Python 3.12+)
    /// AND the global ``PipInstallMode`` is ``PipInstallMode/protected``. The row
    /// then swaps the Install button for a passive "Protected Mode" badge — the
    /// same visual treatment as the "Installed" badge — because a tap could only
    /// fail: pip refuses to write into an externally-managed environment without
    /// an override flag, and previously that failure was silent.
    ///
    /// - Note: In ``PipInstallMode/userSpace`` or ``PipInstallMode/systemWide``
    ///   the flags make the install legal again, so the normal button returns.
    var isProtectedMode: Bool = false

    /// Called when the Install button is tapped.
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(name)
                .font(.body)

            Spacer()

            if isInstalled {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)

                    Text("Installed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 5)
            } else if isInstalling {
                ProgressView()
                    .controlSize(.small)
            } else if isProtectedMode {
                ProtectedModeBadge()
            } else {
                Button {
                    onInstall()
                } label: {
                    Text("Install")
                }
                .appButton(.primary)
                .disabled(!canInstall)
                .opacity(canInstall ? 1.0 : 0.5)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isAlternate ? Color(NSColor.controlAlternatingRowBackgroundColors[1]) : Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Protected Mode Badge

/// Passive badge shown in place of an Install button when PEP 668 Protected
/// mode blocks pip installs on an externally-managed (Python 3.12+) interpreter.
///
/// Mirrors the layout of the "Installed" badge so rows stay visually consistent,
/// using ``PipInstallMode/protected``'s own icon and tint. Hovering explains the
/// state and how to lift it (the install-mode picker).
///
/// - Important: This badge is deliberately NOT a disabled button. A disabled
///   button reads as "temporarily unavailable"; this state is a deliberate,
///   user-chosen policy, presented the same way as "Installed": a fact about
///   the row, not a control.
struct ProtectedModeBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: PipInstallMode.protected.icon)
                .foregroundColor(.secondary)
                .font(.caption)

            Text("Protected Mode")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 5)
        .help("PEP 668: this Python is externally managed, and Protected mode blocks pip installs. Switch the install mode to User space or System-wide to enable installing.")
    }
}

// MARK: - Popular Package Row

/// A ranked row for popular packages with install status and download count.
///
/// Displays a rank number, package name, optional download count, and an install/installed indicator.
///
/// ## Usage
///
/// ```swift
/// PopularPackageRow(
///     package: pkg,
///     rank: index + 1,
///     isAlternate: index % 2 == 1,
///     isInstalled: vm.isInstalled(pkg.name),
///     isInstalling: vm.installingPackage == pkg.name,
///     canInstall: vm.isBrewInstalled,
///     onInstall: { vm.install(pkg) }
/// )
/// ```
struct PopularPackageRow: View, Equatable {
    /// The popular package model.
    let package: PopularPackage
    
    /// The display rank (1-based).
    let rank: Int
    
    /// Whether to use the alternate row background color.
    let isAlternate: Bool
    
    /// Whether this package is already installed.
    let isInstalled: Bool
    
    /// Whether an install operation is in progress for this package.
    let isInstalling: Bool
    
    /// Whether the prerequisite tool is available for installation.
    let canInstall: Bool

    /// Whether installs are blocked by PEP 668 Protected mode.
    ///
    /// See ``InstallablePackageRow/isProtectedMode`` — same semantics, same
    /// default. Only meaningful on the pip tab; brew tabs must leave it `false`.
    var isProtectedMode: Bool = false

    /// Called when the Install button is tapped.
    let onInstall: () -> Void

    /// R1-row: compare only the value inputs (closure ignored) so the row skips
    /// body when an unrelated @Published on the parent VM changes.
    ///
    /// **Gotchas:** Including closures in `Equatable` compliance forces SwiftUI to re-render the row on every parent state change, tanking scrolling performance on large lists.
    /// - Important: `isProtectedMode` MUST participate here — it is derived from
    ///   an external observable (`InstallPreferences.shared.mode`), and omitting
    ///   it would freeze rows on their first-render badge state after the user
    ///   changes the install mode.
    static func == (lhs: PopularPackageRow, rhs: PopularPackageRow) -> Bool {
        lhs.package == rhs.package &&
        lhs.rank == rhs.rank &&
        lhs.isAlternate == rhs.isAlternate &&
        lhs.isInstalled == rhs.isInstalled &&
        lhs.isInstalling == rhs.isInstalling &&
        lhs.canInstall == rhs.canInstall &&
        lhs.isProtectedMode == rhs.isProtectedMode
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(rank)")
                .font(.caption.weight(.bold))
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(package.name)
                    .font(.body)
                
                if let downloads = package.downloads {
                    Text("\(downloads) downloads")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if isInstalled {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    
                    Text("Installed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 5)
            } else if isInstalling {
                ProgressView()
                    .controlSize(.small)
            } else if isProtectedMode {
                ProtectedModeBadge()
            } else {
                Button {
                    onInstall()
                } label: {
                    Text(isInstalling ? "Installing..." : "Install")
                }
                .appButton(.primary)
                .disabled(!canInstall)
                .opacity(canInstall ? 1.0 : 0.5)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isAlternate ? Color(NSColor.controlAlternatingRowBackgroundColors[1]) : Color(NSColor.controlBackgroundColor))
    }
}
