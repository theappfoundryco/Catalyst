//
//  InstallPreferences.swift
//  Catalyst
//
//  Global, persisted "install mode" that decides whether Catalyst overrides
//  PEP 668 (externally-managed environments) when installing/upgrading pip
//  packages on a system Python 3.12+.
//

import SwiftUI
import Combine

/// How pip installs behave on an externally-managed (Python 3.12+) interpreter.
///
/// Only relevant for 3.12+; on older interpreters the flags are omitted. The
/// mode is global and applies to every pip action in the app.
enum PipInstallMode: String, CaseIterable, Identifiable {
    /// Default. Respect system integrity — no override flag.
    case protected
    /// Install into the user site (`--break-system-packages --user`).
    case userSpace
    /// Write into the managed Python (`--break-system-packages`).
    case systemWide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .protected: return "Protected"
        case .userSpace: return "User space"
        case .systemWide: return "System-wide"
        }
    }

    /// One-line, self-explaining description used in the picker/summaries.
    var menuSubtitle: String {
        switch self {
        case .protected: return "Respect system integrity (default)"
        case .userSpace: return "Install to your user site; won't touch system Python"
        case .systemWide: return "Write into the managed Python; can break OS packages"
        }
    }

    /// pip flags appended for an externally-managed (3.12+) interpreter.
    var flags: String {
        switch self {
        case .protected: return ""
        case .userSpace: return "--break-system-packages --user"
        case .systemWide: return "--break-system-packages"
        }
    }

    /// Human-facing rendering of `flags` for the UI (never empty).
    var flagDisplay: String {
        flags.isEmpty ? "none" : flags
    }

    /// Style + copy for the inline status banner under the picker.
    var statusStyle: BannerView.Style {
        switch self {
        case .protected: return .info
        case .userSpace: return .warning
        case .systemWide: return .critical
        }
    }

    var statusMessage: String {
        switch self {
        case .protected:
            return "Respecting PEP 668. Newer packages on this Python may be blocked from installing — pick an override to change that."
        case .userSpace:
            return "User space override: packages install into your user site. Safer, but Homebrew Python may reject --user."
        case .systemWide:
            return "System-wide override active: pip writes into the OS-managed Python. This can break Homebrew/system packages."
        }
    }

    /// Shown in the confirmation dialog when switching away from Protected.
    var confirmMessage: String {
        switch self {
        case .protected: return ""
        case .userSpace:
            return "Installs will use --break-system-packages --user, targeting your user site. This applies to every Python action in Catalyst."
        case .systemWide:
            return "Installs will use --break-system-packages, writing into the OS-managed Python. This can corrupt packages Homebrew manages. It applies to every Python action in Catalyst."
        }
    }

    var icon: String {
        switch self {
        case .protected: return "shield.lefthalf.filled"
        case .userSpace: return "person.crop.circle.badge.exclamationmark"
        case .systemWide: return "exclamationmark.shield.fill"
        }
    }

    var tint: Color {
        switch self {
        case .protected: return .secondary
        case .userSpace: return .orange
        case .systemWide: return .red
        }
    }
}

/// Global, persisted install preference. UI observes `mode`; command builders
/// read the thread-safe `pipFlags(forPythonVersion:)` snapshot.
final class InstallPreferences: ObservableObject {
    static let shared = InstallPreferences()
    private static let key = "pipInstallMode"

    @Published var mode: PipInstallMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.key) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key)
        mode = raw.flatMap(PipInstallMode.init(rawValue:)) ?? .protected
    }

    /// True when any override (not Protected) is selected.
    var isOverrideActive: Bool { mode != .protected }

    /// Thread-safe read (backed by UserDefaults) so command strings can be built
    /// off the main actor. Returns "" when the flags don't apply: Protected mode,
    /// or a pre-3.12 interpreter (where PEP 668 isn't in effect).
    static func pipFlags(forPythonVersion version: String?) -> String {
        if let version, !VersionComparator.requiresBreakSystemPackages(pythonVersion: version) {
            return ""
        }
        let raw = UserDefaults.standard.string(forKey: key)
        let mode = raw.flatMap(PipInstallMode.init(rawValue:)) ?? .protected
        return mode.flags
    }
}
