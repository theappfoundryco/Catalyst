//
//  SnapshotModels.swift
//  Catalyst
//
//  Data contracts for CatalystSnapshot — capturing a Mac dev environment into a
//  portable `.catalystsnapshot` file and restoring it on a new / clean Mac.
//
//  Everything here is `Codable`/`Sendable` value types with a `schemaVersion` and
//  tolerant decoding (Formrules 5.4 / 6.1): a snapshot written by a newer build
//  still loads in an older one, and a missing/renamed section degrades to empty
//  instead of failing the whole decode.
//

import Foundation

/// Schema version constants for the snapshot file format.
enum SnapshotSchema {
    /// The schema version written by this build.
    ///
    /// v2 added `defaultPython` and the passphrase-sealed `secrets` section. Both
    /// are optional and decoded tolerantly, so a v2 file still loads in a v1 build
    /// (those fields are simply ignored) and a v1 file loads here as "no default
    /// pinned, no secrets."
    static let current = 2
    /// The `.catalystsnapshot` bundle is a zip; this is the payload filename inside it.
    static let payloadName = "snapshot.json"
    static let fileExtension = "catalystsnapshot"
}

// MARK: - Section kinds

/// The domains a snapshot can carry. Stable raw values — used as managed-block
/// ids, resume keys, and diff grouping.
enum SnapshotSectionKind: String, Codable, CaseIterable, Sendable {
    case brew, python, pip, shell, shortcuts, git, projects

    /// Ordered for both display and restore dependency order (Homebrew before pip,
    /// interpreters before their packages, shell/shortcuts after).
    static let restoreOrder: [SnapshotSectionKind] = [.brew, .python, .pip, .shell, .shortcuts, .git, .projects]

    var title: String {
        switch self {
        case .brew: return "Homebrew"
        case .python: return "Python interpreters"
        case .pip: return "pip packages"
        case .shell: return "Shell configuration"
        case .shortcuts: return "SmartShortcuts"
        case .git: return "Git identity"
        case .projects: return "Projects"
        }
    }

    /// Icons/colors mirror what each domain already uses elsewhere in the app
    /// (sidebar + screens): brew = orange mug, pip/projects/shortcuts = blue,
    /// shell (Aliases) & git = purple. No new palette entries.
    var icon: String {
        switch self {
        case .brew: return "mug.fill"
        case .python: return "cpu.fill"
        case .pip: return "shippingbox.fill"
        case .shell: return "command.circle.fill"
        case .shortcuts: return "bolt.fill"
        case .git: return "arrow.triangle.branch"
        case .projects: return "cube.fill"
        }
    }

    var color: String {
        switch self {
        case .brew: return "orange"
        case .python: return "blue"
        case .pip: return "blue"
        case .shell: return "purple"
        case .shortcuts: return "blue"
        case .git: return "purple"
        case .projects: return "blue"
        }
    }
}

// MARK: - Source machine metadata

/// Non-identifying metadata about the machine a snapshot was captured on. Used to
/// relocate paths (old home → new home) and to inform the user, never to leak PII:
/// the hostname is stored only as a salted, truncated hash.
struct MachineInfo: Codable, Sendable {
    var os: String
    var arch: String
    var catalystVersion: String
    /// Absolute home directory on the source machine (for path relocation).
    var homeDir: String
    /// Short-name of the source user (for relocation display, not credentials).
    var userName: String
    /// Salted, truncated hash of the hostname — informational only, reversible to nothing.
    var hostnameHash: String
}

// MARK: - Section payloads

struct BrewSnapshot: Codable, Sendable {
    var taps: [String] = []
    var formulae: [String] = []
    var casks: [String] = []

    var isEmpty: Bool { taps.isEmpty && formulae.isEmpty && casks.isEmpty }
}

struct PipPackage: Codable, Sendable, Hashable {
    var name: String
    var version: String?
}

/// A captured Python interpreter plus the packages installed against it.
struct PythonInterpreterSnapshot: Codable, Sendable, Identifiable {
    var id: String { path }
    var version: String
    var path: String
    /// One of `brew` / `pyenv` / `system`.
    var source: String
    var packages: [PipPackage] = []
}

struct GitSnapshot: Codable, Sendable {
    var name: String?
    var email: String?
    var aliases: [String: String] = [:]

    var isEmpty: Bool { (name ?? "").isEmpty && (email ?? "").isEmpty && aliases.isEmpty }
}

/// The captured shell configuration. Two layers:
///  - `catalystConfig`: the Catalyst-owned, sentinel-delimited `.zshrc_catalyst`
///    (aliases, shortcut functions) — carries no user secrets, restored per block.
///  - `mainProfile`: the user's full `~/.zshrc`, **secret-scrubbed** at capture
///    (obvious `export KEY=…`/token assignments replaced with placeholders and
///    listed in `redactedKeys`) so structure migrates without leaking credentials.
struct ShellSnapshot: Codable, Sendable {
    var catalystConfig: String = ""
    /// Ids of the managed blocks present, for diff display.
    var blockIds: [String] = []
    /// The user's full `~/.zshrc`, secret-scrubbed. Empty when not captured.
    var mainProfile: String = ""
    /// Variable names whose values were redacted from `mainProfile` at capture.
    var redactedKeys: [String] = []

    init(catalystConfig: String = "", blockIds: [String] = [],
         mainProfile: String = "", redactedKeys: [String] = []) {
        self.catalystConfig = catalystConfig
        self.blockIds = blockIds
        self.mainProfile = mainProfile
        self.redactedKeys = redactedKeys
    }

    // Tolerant decode so older snapshots (no `mainProfile`) still load fully.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        catalystConfig = (try? c.decodeIfPresent(String.self, forKey: .catalystConfig)) ?? ""
        blockIds = (try? c.decodeIfPresent([String].self, forKey: .blockIds)) ?? []
        mainProfile = (try? c.decodeIfPresent(String.self, forKey: .mainProfile)) ?? ""
        redactedKeys = (try? c.decodeIfPresent([String].self, forKey: .redactedKeys)) ?? []
    }

    var hasMainProfile: Bool { !mainProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var isEmpty: Bool {
        catalystConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasMainProfile
    }
}

/// An installed SmartShortcut (inventory). The shell function itself rides along in
/// `ShellSnapshot` (shortcuts write managed blocks into `.zshrc_catalyst`); this
/// record restores the app's "installed" bookkeeping so the UI reflects it.
struct ShortcutSnapshot: Codable, Sendable, Identifiable {
    var id: String
    var customName: String
    var version: String
}

/// A tracked venv project. Paths are stored relative to the source home when they
/// live under it, so they can be relocated onto a different home / username.
struct ProjectSnapshot: Codable, Sendable, Identifiable {
    var id: UUID
    var name: String
    /// Path relative to source home when `isUnderHome`, else the original absolute path.
    var path: String
    var isUnderHome: Bool
    var pythonVersion: String?
    var venvName: String?
    /// Captured `requirements.txt` lines when present, so the venv can be rebuilt.
    var requirements: [String] = []
}

// MARK: - Top-level snapshot

/// The full snapshot payload (the `snapshot.json` inside a `.catalystsnapshot`).
/// Every section is optional and decoded tolerantly so partial/older/newer files
/// never crash the load.
struct CatalystSnapshot: Codable, Sendable {
    var schemaVersion: Int
    var createdAt: Date
    var source: MachineInfo
    var brew: BrewSnapshot?
    var python: [PythonInterpreterSnapshot]?
    var git: GitSnapshot?
    var shell: ShellSnapshot?
    var shortcuts: [ShortcutSnapshot]?
    var projects: [ProjectSnapshot]?
    /// The default Python (major.minor) Catalyst had pinned on the source Mac via
    /// its `python-default` managed block. Stored as a bare version — never the
    /// source machine's absolute Homebrew path — so restore can re-pin it using
    /// *this* Mac's Homebrew prefix (Intel `/usr/local` vs Apple silicon
    /// `/opt/homebrew`). nil when no Catalyst-set default was in place.
    var defaultPython: String?
    /// Passphrase-sealed API keys / secrets. Optional in every sense: absent on
    /// snapshots captured without a passphrase, and unopenable (→ skipped) if the
    /// passphrase is wrong or lost, which never affects any other section.
    var secrets: EncryptedSecrets?
    /// Capture-time warnings surfaced to the user before export/restore.
    var warnings: [String] = []

    init(schemaVersion: Int = SnapshotSchema.current,
         createdAt: Date = Date(),
         source: MachineInfo,
         brew: BrewSnapshot? = nil,
         python: [PythonInterpreterSnapshot]? = nil,
         git: GitSnapshot? = nil,
         shell: ShellSnapshot? = nil,
         shortcuts: [ShortcutSnapshot]? = nil,
         projects: [ProjectSnapshot]? = nil,
         defaultPython: String? = nil,
         secrets: EncryptedSecrets? = nil,
         warnings: [String] = []) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.source = source
        self.brew = brew
        self.python = python
        self.git = git
        self.shell = shell
        self.shortcuts = shortcuts
        self.projects = projects
        self.defaultPython = defaultPython
        self.secrets = secrets
        self.warnings = warnings
    }

    // Tolerant decode: any missing section → nil/empty rather than a decode failure.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? SnapshotSchema.current
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        source = (try? c.decode(MachineInfo.self, forKey: .source))
            ?? MachineInfo(os: "unknown", arch: "unknown", catalystVersion: "0", homeDir: "", userName: "", hostnameHash: "")
        brew = try? c.decodeIfPresent(BrewSnapshot.self, forKey: .brew)
        python = try? c.decodeIfPresent([PythonInterpreterSnapshot].self, forKey: .python)
        git = try? c.decodeIfPresent(GitSnapshot.self, forKey: .git)
        shell = try? c.decodeIfPresent(ShellSnapshot.self, forKey: .shell)
        shortcuts = try? c.decodeIfPresent([ShortcutSnapshot].self, forKey: .shortcuts)
        projects = try? c.decodeIfPresent([ProjectSnapshot].self, forKey: .projects)
        defaultPython = try? c.decodeIfPresent(String.self, forKey: .defaultPython)
        secrets = try? c.decodeIfPresent(EncryptedSecrets.self, forKey: .secrets)
        warnings = (try? c.decodeIfPresent([String].self, forKey: .warnings)) ?? []
    }

    /// A per-section inventory index for the preview UI (title + item count).
    var inventory: [(kind: SnapshotSectionKind, count: Int)] {
        var out: [(SnapshotSectionKind, Int)] = []
        if let brew, !brew.isEmpty { out.append((.brew, brew.taps.count + brew.formulae.count + brew.casks.count)) }
        if let python, !python.isEmpty { out.append((.python, python.count)) }
        if let python { let n = python.reduce(0) { $0 + $1.packages.count }; if n > 0 { out.append((.pip, n)) } }
        if let shell, !shell.isEmpty { out.append((.shell, shell.blockIds.count + (shell.hasMainProfile ? 1 : 0))) }
        if let shortcuts, !shortcuts.isEmpty { out.append((.shortcuts, shortcuts.count)) }
        if let git, !git.isEmpty { out.append((.git, (git.name != nil ? 1 : 0) + (git.email != nil ? 1 : 0) + git.aliases.count)) }
        if let projects, !projects.isEmpty { out.append((.projects, projects.count)) }
        return out
    }
}

// MARK: - Restore plan

/// The lifecycle state of a single restore action.
///
/// `partial` covers the common pip case where a batch install is resolvable for
/// most packages but a few fail (a version conflict, an externally-managed block):
/// the action neither fully succeeded nor cleanly failed, and the UI shows it as a
/// distinct "some installed" state rather than a scary all-red failure.
enum RestoreStatus: String, Sendable {
    case pending, running, succeeded, failed, partial, skipped
}

/// One planned, user-toggleable restore step. Built by `SnapshotDiffer` (PLAN
/// phase) and executed by `SnapshotRestoreService` (APPLY phase).
struct RestoreAction: Identifiable, Sendable {
    let id = UUID()
    var kind: SnapshotSectionKind
    /// Short, stable key used for resume bookkeeping (e.g. `brew.formula.wget`).
    var key: String
    var title: String
    /// The exact command / description shown in dry-run.
    var commandPreview: String
    /// True when the current Mac already satisfies this item (idempotent skip).
    var alreadySatisfied: Bool
    /// Non-nil when the action can't run yet (e.g. Homebrew missing) — a reason to show.
    var blockedReason: String?
    var selected: Bool
    var status: RestoreStatus
    var message: String?

    var isActionable: Bool { !alreadySatisfied && blockedReason == nil }
}

/// Final tally after an APPLY pass.
struct RestoreSummary: Sendable {
    var succeeded: Int = 0
    var failed: Int = 0
    /// Actions that installed some, but not all, of their items (e.g. a pip set
    /// where a couple of packages hit a version conflict).
    var partial: Int = 0
    var skipped: Int = 0

    /// Whether the run finished with nothing needing the user's attention.
    var isClean: Bool { failed == 0 && partial == 0 }
}
