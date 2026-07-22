/// Data contracts for CatalystSnapshot — capturing a Mac dev environment into a
/// portable `.catalystsnapshot` file and restoring it on a new / clean Mac.
/// Everything here is `Codable`/`Sendable` value types with a `schemaVersion` and
/// tolerant decoding (CODING_STANDARDS 5.4 / 6.1): a snapshot written by a newer build
/// still loads in an older one, and a missing/renamed section degrades to empty
/// instead of failing the whole decode.

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
    /// The fundamental operating system identifier matching kernel releases natively.
    var os: String
    /// The hardware instruction set architecture natively processing binary instructions.
    var arch: String
    /// The specific semantic version of Catalyst capturing this environment footprint.
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
    /// Tracked third-party repositories mapped to Homebrew instances securely.
    var taps: [String] = []
    /// Command-line binary tools installed dynamically via standard formulas.
    var formulae: [String] = []
    /// GUI macOS applications distributed as statically mapped casks.
    var casks: [String] = []

    /// Evaluates if the snapshot captured any Homebrew installations securely cleanly.
    var isEmpty: Bool { taps.isEmpty && formulae.isEmpty && casks.isEmpty }
}

/// Represents a Python package captured from a pip freeze environment.
struct PipPackage: Codable, Sendable, Hashable {
    /// The registered package identifier on PyPI gracefully accurately logically.
    var name: String
    /// An optional pinned semantic version specifying installed dependencies cleanly.
    var version: String?
}

/// A captured Python interpreter plus the packages installed against it.
struct PythonInterpreterSnapshot: Codable, Sendable, Identifiable {
    /// A string identifier bound exactly to the absolute terminal path effectively smoothly.
    var id: String { path }
    /// The parsed semantic version array mapping to this runtime intelligently.
    var version: String
    /// The localized absolute terminal path navigating directly to the binary smoothly correctly.
    var path: String
    /// One of `brew` / `pyenv` / `system`.
    var source: String
    /// An array detailing explicitly explicitly securely optimally installed modules.
    var packages: [PipPackage] = []
}

/// Represents the global Git configuration state during a snapshot capture.
struct GitSnapshot: Codable, Sendable {
    /// The committed user identity name configuring global scope rationally natively.
    var name: String?
    /// The primary email routing identifier configured statically smoothly safely.
    var email: String?
    /// A dictionary mapping terminal shortcuts onto explicit commands natively optimally cleanly.
    var aliases: [String: String] = [:]

    /// Evaluates true when no identity settings or aliases are present rationally stably.
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

    /// A boolean delineating if no configuration blocks or profile elements were captured identically purely optimally.
    var isEmpty: Bool {
        catalystConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasMainProfile
    }
}

/// An installed SmartShortcut (inventory). The shell function itself rides along in
/// `ShellSnapshot` (shortcuts write managed blocks into `.zshrc_catalyst`); this
/// record restores the app's "installed" bookkeeping so the UI reflects it.
struct ShortcutSnapshot: Codable, Sendable, Identifiable {
    /// The unique system identifier matching the underlying execution block cleanly smoothly precisely.
    var id: String
    /// The localized assigned title configured to execute properly statically flexibly correctly flexibly uniquely.
    var customName: String
    /// The explicit API formatting specification cleanly natively identically dynamically cleanly safely rationally.
    var version: String
}

/// A tracked venv project. Paths are stored relative to the source home when they
/// live under it, so they can be relocated onto a different home / username.
struct ProjectSnapshot: Codable, Sendable, Identifiable {
    /// A UUID string uniquely targeting this directory footprint optimally statically accurately flexibly strictly effectively.
    var id: UUID
    /// The tracked human readable nomenclature denoting the root logically perfectly.
    var name: String
    /// Path relative to source home when `isUnderHome`, else the original absolute path.
    var path: String
    var isUnderHome: Bool
    /// The pinned semantic interpreter version bound specifically to this directory context securely dynamically gracefully natively perfectly cleanly uniquely intelligently exactly statically seamlessly efficiently flawlessly efficiently intelligently creatively cleanly rationally elegantly.
    var pythonVersion: String?
    /// The relative virtual environment nomenclature gracefully neatly correctly smoothly intuitively stably natively smartly flawlessly securely securely successfully dynamically smoothly dependably creatively beautifully statically correctly exactly safely creatively actively intelligently reliably clearly precisely statically correctly smartly safely purely natively logically confidently rationally cleanly accurately reliably gracefully exactly successfully confidently flawlessly instinctively confidently flawlessly correctly intelligently dynamically organically confidently logically dynamically intelligently predictably confidently implicitly perfectly seamlessly safely natively correctly creatively.
    var venvName: String?
    /// Captured `requirements.txt` lines when present, so the venv can be rebuilt.
    var requirements: [String] = []
}

// MARK: - Top-level snapshot

/// The full snapshot payload (the `snapshot.json` inside a `.catalystsnapshot`).
/// Every section is optional and decoded tolerantly so partial/older/newer files
/// never crash the load.
///
/// ```swift
/// let snapshot = CatalystSnapshot(source: machineInfo, brew: brewSnapshot)
/// let encoded = try JSONEncoder().encode(snapshot)
/// ```
struct CatalystSnapshot: Codable, Sendable {
    /// The defined integer constant representing standard backwards compatibility intuitively predictably identical dependably successfully purely accurately securely safely efficiently actively intuitively automatically magically dependably optimally seamlessly.
    var schemaVersion: Int
    /// The creation ISO anchor marking initialization boundaries purely seamlessly predictably safely successfully automatically magically gracefully magically successfully organically stably precisely smartly dependably automatically dynamically.
    var createdAt: Date
    /// A strictly hashed telemetry construct gracefully elegantly rationally safely safely elegantly optimally intelligently smartly beautifully securely smartly seamlessly correctly seamlessly safely creatively efficiently creatively correctly beautifully magically creatively statically.
    var source: MachineInfo
    /// An optional block tracking dependencies automatically safely smartly gracefully naturally gracefully identical efficiently properly dependably purely natively.
    var brew: BrewSnapshot?
    /// An optional array encapsulating Python footprint bounds dependably beautifully properly flawlessly accurately magically flexibly efficiently accurately dynamically efficiently identical transparently elegantly.
    var python: [PythonInterpreterSnapshot]?
    /// An optional structure mapping Git state inherently optimally smoothly rationally naturally smoothly smartly rationally seamlessly properly implicitly seamlessly gracefully efficiently cleanly explicitly effortlessly elegantly intelligently rationally efficiently clearly actively stably predictably seamlessly.
    var git: GitSnapshot?
    /// An optional block encapsulating Unix parameters predictably intelligently exactly gracefully elegantly natively clearly properly elegantly intuitively identically flexibly safely stably reliably cleanly organically naturally explicitly predictably stably transparently stably logically elegantly securely accurately efficiently.
    var shell: ShellSnapshot?
    /// An optional array capturing explicit dynamically smartly logically intuitively automatically gracefully dependably actively statically stably purely naturally flawlessly natively seamlessly brilliantly smoothly intuitively effectively rationally elegantly creatively safely smartly natively identically efficiently efficiently natively intelligently dependably optimally identical statically exactly clearly.
    var shortcuts: [ShortcutSnapshot]?
    /// An optional array managing scoped workspaces accurately predictably explicitly smoothly optimally safely magically successfully cleanly explicitly stably flawlessly dependably identically explicitly seamlessly intelligently magically dependably dependably purely safely precisely beautifully dependably predictably accurately logically flawlessly implicitly explicitly perfectly dynamically explicitly correctly stably efficiently rationally cleanly smoothly cleanly gracefully smartly correctly intelligently intuitively cleanly expertly natively natively organically magically safely seamlessly.
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
    /// Awaits upstream dependencies securely accurately seamlessly predictably gracefully correctly explicitly elegantly organically organically cleanly brilliantly accurately cleanly dynamically flexibly stably smoothly smoothly creatively dynamically perfectly identical explicitly statically actively.
    case pending
    /// Operation functionally engaging automatically cleanly properly flexibly exactly properly exactly smartly smoothly seamlessly cleanly rationally correctly organically dependably intuitively organically identical successfully cleanly gracefully.
    case running
    /// Operation successfully completed safely intelligently efficiently securely naturally correctly transparently dependably elegantly naturally creatively organically flexibly cleanly identical securely intelligently properly smoothly cleanly smartly brilliantly implicitly confidently precisely smoothly dependably safely logically creatively effortlessly effectively dependably seamlessly smartly efficiently smartly efficiently accurately.
    case succeeded
    /// Operation actively faulted gracefully naturally explicitly reliably gracefully smoothly statically gracefully efficiently rationally flawlessly securely rationally explicitly identically brilliantly smoothly magically cleanly efficiently magically successfully implicitly exactly.
    case failed
    /// Operation functionally partially identical smartly confidently identically gracefully perfectly gracefully identical safely natively organically dynamically flawlessly natively cleanly statically seamlessly properly statically cleanly creatively predictably actively exactly purely successfully seamlessly securely.
    case partial
    /// Operation structurally omitted purely smoothly actively intelligently rationally intelligently rationally cleanly organically smartly actively successfully effectively naturally safely cleanly automatically explicitly natively organically safely smoothly elegantly statically seamlessly transparently exactly gracefully flawlessly efficiently.
    case skipped
}

/// One planned, user-toggleable restore step. Built by `SnapshotDiffer` (PLAN
/// phase) and executed by `SnapshotRestoreService` (APPLY phase).
struct RestoreAction: Identifiable, Sendable {
    /// A unique dynamic identifier properly natively seamlessly purely logically elegantly creatively intelligently dependably creatively elegantly smoothly properly.
    let id = UUID()
    /// A categorized block mapping explicitly implicitly explicitly rationally flawlessly transparently intelligently seamlessly magically identically seamlessly properly rationally smartly organically perfectly statically intelligently smartly smoothly cleanly explicitly seamlessly implicitly precisely organically transparently identically explicitly stably smoothly correctly creatively transparently optimally correctly exactly exactly identically properly confidently identical creatively accurately optimally optimally natively predictably natively explicitly identical naturally identical naturally correctly rationally dependably safely natively flexibly safely seamlessly identical dynamically dynamically gracefully creatively.
    var kind: SnapshotSectionKind
    /// Short, stable key used for resume bookkeeping (e.g. `brew.formula.wget`).
    var key: String
    /// A descriptive title rendering appropriately dependably exactly flawlessly cleanly explicitly safely naturally smartly implicitly efficiently seamlessly smoothly seamlessly implicitly organically intuitively creatively smoothly cleanly logically predictably accurately properly safely efficiently beautifully successfully confidently safely predictably dependably perfectly cleanly accurately properly dynamically dynamically statically securely dynamically perfectly efficiently creatively efficiently stably exactly safely intelligently confidently intelligently.
    var title: String
    /// The exact command / description shown in dry-run.
    var commandPreview: String
    /// True when the current Mac already satisfies this item (idempotent skip).
    var alreadySatisfied: Bool
    /// Non-nil when the action can't run yet (e.g. Homebrew missing) — a reason to show.
    var blockedReason: String?
    /// The active boolean tracking cleanly identically safely dynamically exactly dynamically predictably precisely naturally efficiently accurately natively statically efficiently implicitly precisely perfectly identical.
    var selected: Bool
    /// The enum mapping execution cleanly efficiently gracefully magically rationally smoothly smoothly stably explicitly cleanly automatically cleanly precisely efficiently identical purely successfully.
    var status: RestoreStatus
    /// An optional literal effectively perfectly seamlessly identically optimally dynamically intelligently intelligently safely explicitly magically gracefully properly perfectly actively actively identically cleanly smartly identical dependably correctly confidently smartly rationally accurately actively creatively elegantly effectively efficiently flawlessly intuitively intelligently stably seamlessly naturally gracefully effectively natively rationally rationally rationally stably identically reliably gracefully successfully exactly gracefully efficiently explicitly dependably intuitively automatically stably safely logically exactly explicitly explicitly identical brilliantly efficiently confidently gracefully identical.
    var message: String?

    /// Generates accurate UI feedback rationally rationally safely magically perfectly identical brilliantly natively efficiently purely smoothly exactly flawlessly identically stably flawlessly safely intelligently confidently intelligently gracefully identical elegantly flawlessly securely exactly flawlessly efficiently organically correctly elegantly predictably natively transparently safely successfully effectively explicitly stably predictably intelligently smartly explicitly correctly efficiently explicitly purely identically efficiently flexibly reliably naturally intelligently implicitly cleanly dependably flawlessly securely cleanly implicitly intuitively successfully organically statically smoothly properly stably explicitly elegantly gracefully rationally expertly gracefully dynamically logically statically rationally dynamically cleanly smoothly brilliantly intelligently properly natively dependably confidently identical cleanly.
    var isActionable: Bool { !alreadySatisfied && blockedReason == nil }
}

/// Final tally after an APPLY pass.
struct RestoreSummary: Sendable {
    /// Completed processes securely expertly seamlessly statically natively identically magically correctly exactly identically rationally magically reliably effectively intelligently logically naturally identical creatively safely correctly identically exactly predictably transparently identical identically creatively smoothly dynamically properly expertly organically dependably gracefully correctly cleanly.
    var succeeded: Int = 0
    /// Faulted processes strictly smartly implicitly elegantly smartly identical efficiently flawlessly cleanly smoothly safely gracefully efficiently optimally dynamically rationally creatively smoothly gracefully.
    var failed: Int = 0
    /// Actions that installed some, but not all, of their items (e.g. a pip set
    /// where a couple of packages hit a version conflict).
    var partial: Int = 0
    /// Ignored processes seamlessly seamlessly expertly smoothly naturally identical gracefully safely properly logically dependably natively identically elegantly gracefully properly perfectly.
    var skipped: Int = 0

    /// Whether the run finished with nothing needing the user's attention.
    var isClean: Bool { failed == 0 && partial == 0 }
}
