import Foundation

/// Shared Orphanage models — the value types passed between `OrphanScanner`,
/// `OrphanMatcher`, `OrphanCleanupService` and the ViewModel.
///
/// Deliberately **Foundation-only** (CODING_STANDARDS 1.2: "a Model never imports
/// SwiftUI"). `CruftModels` predates that rule and carries `Color` directly; the
/// display-only `color` for these types lives in an extension in
/// `Views/Components/OrphanageCards.swift` instead. `icon` stays here because an
/// SF Symbol name is just a `String`.

// MARK: - Category

/// Whether a leftover lives in the current user's home or affects the whole Mac.
///
/// System-scope items need root to remove, so Phase 1 surfaces them **read-only**
/// (see `LeftoverCategory.isUserRemovable`). Mirrors how `LoginItemsService`
/// already treats `/Library/LaunchAgents` and `/Library/LaunchDaemons`.
enum LeftoverScope: String, Sendable, Codable {
    /// Under `~/Library` — removable without elevated privileges.
    case user
    /// Under `/Library` or a package receipt — affects every user on the Mac.
    case system
}

/// A known class of residue an uninstalled app leaves behind.
///
/// The case set doubles as the scan plan: `OrphanScanner` walks one root per
/// user-scope case, so adding a case here is how you add a scan location.
///
/// ```swift
/// let category = LeftoverCategory.caches
/// print(category.title)           // "Caches"
/// print(category.isUserRemovable) // true
/// ```
enum LeftoverCategory: String, CaseIterable, Identifiable, Sendable, Codable {
    /// `~/Library/Application Support/<AppName>`
    case applicationSupport
    /// `~/Library/Caches/<bundle id or AppName>`
    case caches
    /// `~/Library/Preferences/<bundle id>.plist`
    case preferences
    /// `~/Library/Logs/<AppName>`
    case logs
    /// `~/Library/Saved Application State/<bundle id>.savedState`
    case savedState
    /// `~/Library/HTTPStorages/<bundle id>`
    case httpStorages
    /// `~/Library/WebKit/<bundle id>`
    case webKit
    /// `~/Library/Containers/<bundle id>` — sandboxed / Mac App Store apps.
    case containers
    /// `~/Library/Group Containers/*<bundle id>*`
    case groupContainers
    /// `~/Library/LaunchAgents/<bundle id>*.plist`
    case userLaunchAgent
    /// `/Library/LaunchAgents` — system scope.
    case systemLaunchAgent
    /// `/Library/LaunchDaemons` — system scope.
    case systemLaunchDaemon
    /// `/Library/PrivilegedHelperTools` — system scope.
    case privilegedHelper
    /// A `pkgutil` install receipt with no surviving app.
    case receipt

    /// The stable string identifier, mapping directly to the raw value.
    var id: String { rawValue }

    /// Human-readable category name shown on the item row.
    var title: String {
        switch self {
        case .applicationSupport:  return "Application Support"
        case .caches:              return "Caches"
        case .preferences:         return "Preferences"
        case .logs:                return "Logs"
        case .savedState:          return "Saved State"
        case .httpStorages:        return "HTTP Storage"
        case .webKit:              return "WebKit Data"
        case .containers:          return "Container"
        case .groupContainers:     return "Group Container"
        case .userLaunchAgent:     return "Launch Agent"
        case .systemLaunchAgent:   return "Launch Agent (system)"
        case .systemLaunchDaemon:  return "Launch Daemon (system)"
        case .privilegedHelper:    return "Privileged Helper"
        case .receipt:             return "Install Receipt"
        }
    }

    /// SF Symbol identifying the category in lists.
    var icon: String {
        switch self {
        case .applicationSupport:  return "folder.fill"
        case .caches:              return "memorychip"
        case .preferences:         return "slider.horizontal.3"
        case .logs:                return "doc.text.fill"
        case .savedState:          return "arrow.uturn.backward.circle.fill"
        case .httpStorages:        return "network"
        case .webKit:              return "globe"
        case .containers:          return "shippingbox.fill"
        case .groupContainers:     return "square.stack.3d.up.fill"
        case .userLaunchAgent:     return "bolt.fill"
        case .systemLaunchAgent:   return "bolt.shield.fill"
        case .systemLaunchDaemon:  return "bolt.shield.fill"
        case .privilegedHelper:    return "lock.shield.fill"
        case .receipt:             return "doc.badge.gearshape.fill"
        }
    }

    /// User-home vs whole-Mac.
    var scope: LeftoverScope {
        switch self {
        case .systemLaunchAgent, .systemLaunchDaemon, .privilegedHelper, .receipt:
            return .system
        default:
            return .user
        }
    }

    /// Whether Phase 1 can actually remove this without a privileged helper.
    ///
    /// **Gotchas:** The `CatalystHelper` XPC target does not exist in the Xcode
    /// project yet (`PrivilegedHelper/README.md` — the target must be created in
    /// the GUI). Until it does, `SMAppService.daemon(...)` fails at runtime, so
    /// every system-scope item is detected and shown but never actioned. Do not
    /// "fix" this by shelling out to `sudo` — CODING_STANDARDS 2.1.
    var isUserRemovable: Bool { scope == .user }
}

// MARK: - Match confidence

/// How strongly a leftover was tied to a vendor, and therefore how much trust the
/// "this app is gone" verdict deserves.
///
/// **Rationale:** CODING_STANDARDS 8.3 requires artifacts be identified by *marker*,
/// not by name. A bundle identifier is the marker equivalent here. Vendor-token and
/// name matching are heuristics, so they are labelled and excluded from bulk
/// selection rather than being silently treated as equivalent evidence.
///
/// The `Int` raw values exist only to order the cases; `Comparable` is what the
/// call sites use, so a group can report its **weakest** member's evidence.
///
/// ```swift
/// min(MatchConfidence.bundleID, .nameOnly) // .nameOnly
/// MatchConfidence.nameOnly.isBulkSelectable // false
/// ```
enum MatchConfidence: Int, Comparable, Sendable, Codable {
    /// Matched on a full bundle identifier parsed out of the path.
    case bundleID = 3
    /// Matched a versioned lineage of a bundle id (`iMazing2Mac` → `iMazing3Mac`).
    case vendorLineage = 2
    /// Matched only on a folder name against installed display names.
    case nameOnly = 1

    /// Orders cases by strength of evidence, so `min()` over a group yields its
    /// least certain member.
    ///
    /// - Parameters:
    ///   - lhs: The confidence on the left of the comparison.
    ///   - rhs: The confidence on the right of the comparison.
    /// - Returns: `true` when `lhs` rests on weaker evidence than `rhs`.
    static func < (lhs: MatchConfidence, rhs: MatchConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Short chip label.
    var label: String {
        switch self {
        case .bundleID:      return "Bundle ID"
        case .vendorLineage: return "Vendor"
        case .nameOnly:      return "Name only"
        }
    }

    /// Explanation shown in the row tooltip.
    var detail: String {
        switch self {
        case .bundleID:
            return "Matched on a bundle identifier — no installed app claims it."
        case .vendorLineage:
            return "Matched a vendor's bundle-id lineage. Check before removing."
        case .nameOnly:
            return "Matched on folder name only. Shared SDK folders can look orphaned — verify manually."
        }
    }

    /// Whether "Select high-confidence" may auto-select this.
    var isBulkSelectable: Bool { self == .bundleID }
}

// MARK: - Leftover item

/// One residual file or folder found on disk with no surviving owner app.
///
/// ```swift
/// let item = LeftoverItem(
///     url: URL(fileURLWithPath: "/Users/me/Library/Caches/com.vendor.app"),
///     category: .caches,
///     size: 12_400_000,
///     lastModified: .now,
///     bundleID: "com.vendor.app",
///     appName: "Vendor App",
///     confidence: .bundleID
/// )
/// print(item.formattedSize) // "12.4 MB"
/// ```
struct LeftoverItem: Identifiable, Equatable, Sendable {
    /// Stable identity for SwiftUI diffing.
    let id: UUID
    /// Absolute location on disk.
    let url: URL
    /// Which known leftover location it came from.
    let category: LeftoverCategory
    /// Byte size (recursive for directories).
    let size: Int64
    /// Filesystem modification date, shown so the user can judge staleness.
    let lastModified: Date
    /// The bundle identifier parsed out of the path, when the path carries one.
    let bundleID: String?
    /// Display name of the app this appears to belong to.
    let appName: String
    /// How the orphan verdict was reached.
    let confidence: MatchConfidence

    /// Creates a leftover record.
    ///
    /// - Parameters:
    ///   - id: Stable identity; defaults to a fresh `UUID`.
    ///   - url: Absolute location on disk.
    ///   - category: The scan root this was found under.
    ///   - size: Byte size, recursive for directories.
    ///   - lastModified: Filesystem modification date.
    ///   - bundleID: Bundle identifier parsed from the path, when present.
    ///   - appName: Display name to attribute the item to.
    ///   - confidence: How the orphan verdict was reached.
    init(
        id: UUID = UUID(),
        url: URL,
        category: LeftoverCategory,
        size: Int64,
        lastModified: Date,
        bundleID: String?,
        appName: String,
        confidence: MatchConfidence
    ) {
        self.id = id
        self.url = url
        self.category = category
        self.size = size
        self.lastModified = lastModified
        self.bundleID = bundleID
        self.appName = appName
        self.confidence = confidence
    }

    /// Absolute path string.
    var path: String { url.path }

    /// Basename shown as the row title.
    var simpleName: String { url.lastPathComponent }

    /// Localized byte size.
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Path components that suggest this holds real user data rather than junk.
    ///
    /// **Rationale:** In the iMazing case `Application Support/iMazing/Backups`
    /// holds real device backups while its `…/Temp` child is disposable. Matching
    /// on **any** component below the scan root (not just the leaf) is what
    /// catches the parent.
    ///
    /// **Gotchas:** `library` is deliberately absent. Every path this feature
    /// touches lives under `~/Library`, so including it flagged **every** item as
    /// risky — a warning that fires on everything teaches people to click through
    /// it, which is the opposite of what the extra confirmation is for.
    static let riskyKeywords: Set<String> = [
        "backup", "backups", "data", "vault", "documents",
        "archive", "archives", "database", "databases"
    ]

    /// Names of the scan roots, used to find where the meaningful part of a path
    /// begins.
    private static let rootNames: Set<String> = [
        "Application Support", "Caches", "Preferences", "Logs",
        "Saved Application State", "HTTPStorages", "WebKit",
        "Containers", "Group Containers", "LaunchAgents",
        "LaunchDaemons", "PrivilegedHelperTools"
    ]

    /// True when a path component **below the scan root** looks data-bearing,
    /// which forces the extra per-item confirmation in the UI.
    ///
    /// Components above and including the root (`Users`, `me`, `Library`,
    /// `Application Support`) are ignored — they are constant across every result
    /// and carry no signal.
    var isRisky: Bool {
        let components = url.pathComponents
        let rootIndex = components.lastIndex { Self.rootNames.contains($0) }
        let meaningful = rootIndex.map { components[components.index(after: $0)...] }
            ?? components[...]
        return meaningful.contains { Self.riskyKeywords.contains($0.lowercased()) }
    }

    /// System-scope items are detected but cannot be actioned in Phase 1.
    var isActionable: Bool { category.isUserRemovable }
}

// MARK: - Grouping

/// Leftovers bucketed by the app they appear to belong to, for the grouped list.
struct OrphanGroup: Identifiable, Equatable {
    /// Stable identity for SwiftUI diffing.
    let id: UUID
    /// App display name used as the group header (never a raw path).
    let appName: String
    /// The individual leftovers attributed to this app.
    var items: [LeftoverItem]
    /// Disclosure state owned by the ViewModel.
    var isExpanded: Bool

    /// Creates a group of leftovers attributed to one app.
    ///
    /// - Parameters:
    ///   - id: Stable identity; defaults to a fresh `UUID`.
    ///   - appName: Display name used as the group header.
    ///   - items: The leftovers attributed to that app.
    ///   - isExpanded: Initial disclosure state; the ViewModel owns it thereafter.
    init(id: UUID = UUID(), appName: String, items: [LeftoverItem], isExpanded: Bool = false) {
        self.id = id
        self.appName = appName
        self.items = items
        self.isExpanded = isExpanded
    }

    /// Combined reclaimable size across the group.
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    /// Localized combined size.
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    /// The weakest evidence in the group — the header chip shows this, so a group
    /// is never presented as more certain than its shakiest member.
    var confidence: MatchConfidence {
        items.map(\.confidence).min() ?? .nameOnly
    }

    /// Whether any member holds apparent user data.
    var containsRisky: Bool { items.contains { $0.isRisky } }

    /// Whether any member needs root and so cannot be actioned yet.
    var containsSystemScope: Bool { items.contains { !$0.isActionable } }
}

// MARK: - Quarantine

/// One quarantined item, persisted so a restore survives app relaunch.
///
/// **Rationale:** CODING_STANDARDS 2.3 prefers `trashItem`, but the Trash loses
/// provenance (nothing records where a folder came from) and gets emptied on the
/// user's schedule rather than ours. Orphanage moves into a Catalyst-owned staging
/// directory on the **same volume**, so the move is an atomic rename, and keeps
/// this manifest so every item can be put back exactly where it was.
struct QuarantineRecord: Identifiable, Codable, Equatable, Sendable {
    /// Stable identity, also used as the on-disk staging subdirectory name.
    let id: UUID
    /// Where the item lived before quarantine — the restore destination.
    let originalPath: String
    /// Where it lives now, inside the staging directory.
    let quarantinePath: String
    /// Category it was found under.
    let category: LeftoverCategory
    /// Size at quarantine time.
    let size: Int64
    /// App the item was attributed to.
    let appName: String
    /// Bundle identifier, when known — re-checked at purge time so a reinstalled
    /// app's data is never purged on schedule.
    let bundleID: String?
    /// When it was quarantined.
    let quarantinedAt: Date

    /// When the grace period lapses and the item becomes eligible for purge.
    var expiresAt: Date {
        Calendar.current.date(byAdding: .day, value: Self.gracePeriodDays, to: quarantinedAt)
            ?? quarantinedAt
    }

    /// Whole days remaining before purge eligibility, floored at zero.
    var daysRemaining: Int {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0
        return max(days, 0)
    }

    /// Localized size.
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// How long quarantined items are retained before becoming purgeable.
    static let gracePeriodDays = 30
}

// MARK: - Audit

/// A single recorded action, appended to the on-disk audit log.
struct OrphanAuditEntry: Codable, Identifiable, Equatable, Sendable {
    /// What happened to a path.
    enum Action: String, Codable, Sendable {
        /// Moved into the staging directory.
        case quarantined
        /// Put back at its original path.
        case restored
        /// Permanently removed after the grace period.
        case purged
        /// A launchd job was booted out before its plist was quarantined.
        case unloadedAgent
        /// An action was attempted and did not complete.
        case failed
    }

    /// Stable identity for the log list.
    let id: UUID
    /// When the action was recorded.
    let timestamp: Date
    /// What was done.
    let action: Action
    /// The path acted on — the original location, not the staging one.
    let path: String
    /// Byte size at the time of the action.
    let size: Int64
    /// Free-text context (error category, launchd label, …). Never secrets —
    /// CODING_STANDARDS 2.10.
    let detail: String

    /// Creates an audit entry.
    ///
    /// - Parameters:
    ///   - id: Stable identity; defaults to a fresh `UUID`.
    ///   - timestamp: When it happened; defaults to now.
    ///   - action: What was done.
    ///   - path: The original path acted on.
    ///   - size: Byte size at the time of the action.
    ///   - detail: Free-text context. Never secrets — CODING_STANDARDS 2.10.
    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        action: Action,
        path: String,
        size: Int64,
        detail: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.path = path
        self.size = size
        self.detail = detail
    }
}
