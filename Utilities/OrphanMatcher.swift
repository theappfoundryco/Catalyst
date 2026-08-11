import Foundation

/// Pure, background-safe logic for Orphanage: which paths may ever be touched
/// (`OrphanPathValidator`) and whether a leftover still has a living owner
/// (`OrphanMatcher`). No state, no I/O beyond `FileManager` metadata reads, so
/// both run freely off the main actor.

// MARK: - Path validation

/// The allowlist gate every Orphanage delete must pass.
///
/// **Rationale:** CODING_STANDARDS 2.3 routes destructive deletes through
/// `PrivilegesService.validateSafeToDeletePath`, but that function *blocklists*
/// `~/Library`, `/Library`, `~/Documents` and `~/Desktop` — which is exactly and
/// entirely where Orphanage works. Widening it would silently widen Cruft Sweeper
/// and the Homebrew cleanup paths that share it, so Orphanage carries its own,
/// far narrower allowlist instead. **Do not merge these two validators.** The
/// duplication is the safety property.
///
/// ```swift
/// OrphanPathValidator.isEligible(url) // false for ~/Library/Caches itself
/// ```
enum OrphanPathValidator {

    /// The only directories whose **children** may be quarantined. The roots
    /// themselves are never eligible — see ``isEligible(_:)``.
    static func allowedRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library")
        return [
            library.appendingPathComponent("Application Support"),
            library.appendingPathComponent("Caches"),
            library.appendingPathComponent("Preferences"),
            library.appendingPathComponent("Logs"),
            library.appendingPathComponent("Saved Application State"),
            library.appendingPathComponent("HTTPStorages"),
            library.appendingPathComponent("WebKit"),
            library.appendingPathComponent("Containers"),
            library.appendingPathComponent("Group Containers"),
            library.appendingPathComponent("LaunchAgents")
        ]
    }

    /// Read-only system locations. Scanned and displayed, never eligible for a
    /// delete in Phase 1 — no privileged helper target exists yet.
    static let systemRoots: [URL] = [
        URL(fileURLWithPath: "/Library/LaunchAgents"),
        URL(fileURLWithPath: "/Library/LaunchDaemons"),
        URL(fileURLWithPath: "/Library/PrivilegedHelperTools")
    ]

    /// Absolute path prefixes that are never touched under any circumstance.
    private static let blockedPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/private/var/db",
        "/Applications", "/Library/Apple"
    ]

    /// Bundle-identifier prefixes owned by the OS.
    private static let blockedBundlePrefixes = ["com.apple.", "com.Apple."]

    /// Whether `url` sits directly inside one of the allowed roots and is safe to
    /// quarantine.
    ///
    /// **Flow:**
    /// 1. Reject empty, `/`, and anything under a blocked prefix.
    /// 2. Reject Apple-owned bundle identifiers anywhere in the name.
    /// 3. Reject symlinks outright — never act on a link's target
    ///    (`isEligible` is the only gate, so this is where that stops).
    /// 4. Reject the allowed roots themselves; require a **direct child**.
    /// 5. Reject anything inside Catalyst's own staging directory.
    ///
    /// - Parameter url: The candidate leftover path.
    /// - Returns: `true` only when every check passes.
    static func isEligible(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard !path.isEmpty, path != "/" else { return false }

        for blocked in blockedPrefixes where path == blocked || path.hasPrefix(blocked + "/") {
            return false
        }

        let name = url.lastPathComponent
        for prefix in blockedBundlePrefixes where name.hasPrefix(prefix) {
            return false
        }

        /// Symlinks are refused rather than resolved. Following one would let a
        /// crafted link inside a cache directory redirect a delete anywhere the
        /// user can write, and would also let a self-referential link spin a
        /// recursive size walk forever.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return false
        }

        /// Never the staging directory — quarantining the quarantine would strand
        /// every pending restore.
        if path.hasPrefix(quarantineRoot().standardizedFileURL.path) { return false }

        /// Must be a *direct child* of an allowed root. This is the single most
        /// important check: it makes `~/Library/Caches` itself ineligible while
        /// `~/Library/Caches/com.vendor.app` passes, so a bug upstream can never
        /// escalate into wiping an entire Library subtree.
        let parent = url.standardizedFileURL.deletingLastPathComponent().path
        return allowedRoots().contains { $0.standardizedFileURL.path == parent }
    }

    /// Catalyst's staging directory for quarantined items.
    ///
    /// Lives on the same volume as `~/Library`, so every quarantine move is an
    /// atomic rename rather than a copy — fast, and it can't half-succeed.
    static func quarantineRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Catalyst/Quarantine")
    }
}

// MARK: - Installed app reference set

/// One app that currently exists on this Mac.
struct InstalledApp: Sendable, Equatable {
    /// `CFBundleIdentifier`, lowercased.
    let bundleID: String
    /// Display name, lowercased.
    let name: String
}

/// The set of bundle identifiers and names that count as "still installed".
///
/// Built once per scan and re-built immediately before any delete — an app can be
/// reinstalled between scanning and confirming.
struct InstalledAppIndex: Sendable {
    /// Lowercased bundle identifiers of every app found.
    let bundleIDs: Set<String>
    /// Lowercased display names of every app found.
    let names: Set<String>
    /// Vendor lineage tokens, e.g. `imazing` from `com.DigiDNA.iMazing3Mac`.
    let lineageTokens: Set<String>

    /// An index that considers nothing installed — used only in previews/tests.
    static let empty = InstalledAppIndex(bundleIDs: [], names: [], lineageTokens: [])
}

// MARK: - Matching

/// Decides whether a leftover path still has a living owner.
///
/// **Rationale:** Bundle-id first, name second (CODING_STANDARDS 8.3 in spirit —
/// match on a marker, not a label). A bare `Sentry` or `Firebase` folder shares a
/// name with SDKs that many installed apps embed; treating that as an orphan
/// because no app is *called* Sentry is exactly the false positive bundle-id
/// matching avoids.
struct OrphanMatcher: Sendable {

    /// Vendor/product tokens too generic to ever justify a name-only orphan
    /// verdict. These appear under `Application Support` and `Caches` for dozens
    /// of unrelated apps.
    private static let ambiguousTokens: Set<String> = [
        "sentry", "firebase", "crashlytics", "electron", "chromium", "google",
        "microsoft", "adobe", "unity", "mono", "java", "python", "node",
        "cache", "caches", "temp", "tmp", "logs", "data", "storage",
        "updater", "sparkle", "crashreporter", "analytics", "com", "org", "io", "net"
    ]

    /// Apple system components that appear under `Caches` / `Application Support`
    /// as plain names with no bundle identifier and no `.app` anywhere on disk.
    ///
    /// **Gotchas:** These are macOS's own working data. A dry run against a real
    /// Mac surfaced `GeoServices`, `Animoji` and `networkserviceproxy` as
    /// "orphaned" purely because nothing in `/Applications` is named that — they
    /// are the exact false positive spec §4 ("never touch `com.apple.*`") is
    /// trying to prevent, just wearing a name instead of a bundle id.
    private static let appleSystemComponents: Set<String> = [
        "geoservices", "animoji", "networkserviceproxy", "cloudkit", "callservicesd",
        "knowledge", "siri", "spotlight", "coreduetd", "assistant", "familycircle",
        "icloud", "appleinternal", "mobilesync", "sharedfilelist", "accountsd",
        "passkit", "photoslegacyupgrade", "screentime", "storekit", "syncedpreferences",
        "corespeech", "translationservices", "avfoundation", "audiocomponents"
    ]

    /// Command-line tooling that caches under `~/Library` but ships no `.app`, so
    /// no amount of scanning `/Applications` will ever find its owner.
    ///
    /// **Gotchas:** The same dry run offered `typescript`, `node-gyp`,
    /// `ms-playwright-go`, `Jedi`, `.wrangler` and `org.swift.swiftpm` for
    /// deletion while every one of those tools was installed and in use. This is
    /// CODING_STANDARDS 8.4 restated: developer tool homes are not user leftovers.
    private static let toolchainCaches: Set<String> = [
        "typescript", "node-gyp", "ms-playwright", "ms-playwright-go", "jedi",
        "wrangler", "swiftpm", "org.swift.swiftpm", "pip", "pypoetry", "yarn",
        "npm", "pnpm", "deno", "bun", "go-build", "golang", "cargo", "rustup",
        "homebrew", "electron", "puppeteer", "selenium", "esbuild", "vite",
        "turbo", "nx", "gradle", "maven", "cocoapods", "carthage", "bazel",
        "helm", "terraform", "docker", "colima", "podman", "uv", "ruff"
    ]

    /// Strips a group-container prefix so the underlying bundle id is visible.
    ///
    /// Group containers are named `group.<bundle id>` or `<TeamID>.<bundle id>`.
    ///
    /// **Gotchas:** Without this, `group.com.apple.CoreSpeech` sails straight past
    /// the `com.apple.` guard — it does not *start* with `com.apple.`, it starts
    /// with `group.`. The dry run flagged two pieces of live Apple system data
    /// exactly this way.
    static func stripContainerPrefix(_ name: String) -> String {
        if name.lowercased().hasPrefix("group.") {
            return String(name.dropFirst("group.".count))
        }
        /// A leading Apple Team ID is 10 alphanumeric characters.
        let labels = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        if labels.count == 2, labels[0].count == 10,
           labels[0].allSatisfy({ $0.isLetter || $0.isNumber }),
           labels[0].contains(where: \.isNumber) {
            return String(labels[1])
        }
        return name
    }

    /// Whether a name carries a leading Apple Team ID (`UBF8T346G9.Office`).
    ///
    /// **Rationale:** A Team ID identifies the **vendor**, not the app, so the
    /// remainder is often a shared suite name rather than any single bundle id —
    /// `UBF8T346G9.Office` is Microsoft's, used by Word, Excel and PowerPoint
    /// alike. Proving it unowned would mean checking installed apps' code
    /// signatures for that team. Until that exists, these are reported at reduced
    /// confidence rather than presented as certain.
    static func hasTeamIDPrefix(_ name: String) -> Bool {
        let labels = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard labels.count == 2, labels[0].count == 10 else { return false }
        return labels[0].allSatisfy { $0.isLetter || $0.isNumber }
            && labels[0].contains(where: \.isNumber)
    }

    /// Whether a component belongs to Apple, accounting for container prefixes.
    static func isAppleOwned(_ component: String) -> Bool {
        let stripped = stripContainerPrefix(component).lowercased()
        return stripped.hasPrefix("com.apple.")
            || appleSystemComponents.contains(stripped)
    }

    /// Trailing version digits on a bundle-id leaf, e.g. `iMazing3Mac` → `imazingmac`.
    ///
    /// **Gotchas:** Without this, upgrading iMazing 2 → 3 makes the version-2
    /// support folder look abandoned and offers the user's device backups for
    /// deletion. An upgrade is not an uninstall.
    static func lineageToken(from bundleID: String) -> String {
        let leaf = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        let stripped = leaf.filter { !$0.isNumber }
        return stripped.lowercased()
    }

    /// Extracts a bundle identifier from a path component when it looks like one.
    ///
    /// - Parameter component: A file or folder basename.
    /// - Returns: The lowercased bundle id, or `nil` if the name isn't one.
    static func bundleID(fromComponent component: String) -> String? {
        /// Strip the extensions these locations use before testing the shape.
        var name = component
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }

        /// A bundle id needs at least two dot-separated, non-empty labels and no
        /// path or whitespace characters.
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        guard !name.contains(" "), !name.contains("/") else { return nil }

        /// Reject things like "1.2.3" or "README.md" that split cleanly but aren't
        /// identifiers — require at least one label of 2+ letters.
        guard parts.contains(where: { $0.count >= 2 && $0.allSatisfy(\.isLetter) }) else {
            return nil
        }
        return name.lowercased()
    }

    /// The verdict for a single candidate path component.
    enum Verdict: Sendable, Equatable {
        /// An installed app claims this — leave it alone.
        case owned
        /// No installed app claims it; carries the evidence strength.
        case orphaned(MatchConfidence)
    }

    /// Classifies one leftover basename against the installed reference set.
    ///
    /// **Flow:**
    /// 1. If the component parses as a bundle id, match it against installed ids
    ///    exactly, then against the vendor lineage (upgrade-safe).
    /// 2. Otherwise fall back to a name comparison, but only for names distinctive
    ///    enough to mean anything.
    ///
    /// - Parameters:
    ///   - component: The basename found in a leftover location.
    ///   - index: The set of currently installed apps.
    /// - Returns: Whether the item is owned, and how confident an orphan verdict is.
    func classify(component: String, against index: InstalledAppIndex) -> Verdict {
        /// Apple's own data is never a candidate, whether it announces itself as
        /// `com.apple.*`, `group.com.apple.*`, or a bare system component name.
        if Self.isAppleOwned(component) { return .owned }

        /// Tooling that ships no `.app` can never be matched against
        /// `/Applications`, so scanning would always call it orphaned.
        let strippedLower = Self.stripContainerPrefix(component).lowercased()
        if Self.toolchainCaches.contains(strippedLower) { return .owned }
        if strippedLower.hasPrefix(".") { return .owned }

        /// Group containers carry a `group.`/Team-ID prefix; match on what's underneath.
        let normalized = Self.stripContainerPrefix(component)

        if let bundleID = Self.bundleID(fromComponent: normalized) {
            if index.bundleIDs.contains(bundleID) { return .owned }

            /// An installed app in the same versioned lineage keeps this owned.
            let lineage = Self.lineageToken(from: bundleID)
            if !lineage.isEmpty, index.lineageTokens.contains(lineage) { return .owned }

            let labels = bundleID.split(separator: ".").map(String.init)

            /// A bundle id whose vendor segment matches an installed app's name is
            /// weaker evidence but still enough to spare it.
            if labels.contains(where: { index.names.contains($0) }) { return .owned }

            /// A group container is often a *truncation* of the app's real bundle
            /// id — `UBF8T346G9.Office` belongs to `com.microsoft.Office.Word`.
            /// Treat any installed id that contains a distinctive label as owner.
            if labels.contains(where: { label in
                label.count >= 4
                    && !Self.ambiguousTokens.contains(label)
                    && index.bundleIDs.contains(where: { $0.contains(label) })
            }) { return .owned }

            if Self.toolchainCaches.contains(where: { bundleID.contains($0) }) { return .owned }

            /// A Team-ID-prefixed group container names a vendor, not an app, so
            /// it never earns full bundle-id confidence.
            return .orphaned(Self.hasTeamIDPrefix(component) ? .vendorLineage : .bundleID)
        }

        /// Name-only path. Anything generic is treated as owned (i.e. skipped)
        /// rather than surfaced — a false negative here costs the user some disk
        /// space, a false positive costs them data.
        let lower = normalized.lowercased()
        if index.names.contains(lower) { return .owned }
        if Self.ambiguousTokens.contains(lower) { return .owned }
        if lower.count < 4 { return .owned }

        /// A bare name that appears anywhere inside an installed bundle id belongs
        /// to something still on the Mac.
        if index.bundleIDs.contains(where: { $0.contains(lower) }) { return .owned }

        /// A name that is a prefix/suffix of an installed app's name (or vice
        /// versa) is very likely the same vendor — "Slack" vs "Slack Helper".
        if index.names.contains(where: { $0.contains(lower) || lower.contains($0) }) {
            return .owned
        }

        /// The lineage set also holds installed apps' stripped bundle leaves, so
        /// "iMazing" as a plain folder name still matches `com.DigiDNA.iMazing3Mac`.
        if index.lineageTokens.contains(where: { $0.contains(lower) || lower.contains($0) }) {
            return .owned
        }

        /// A Team-ID group container whose remainder isn't a bundle id (`…​.Office`)
        /// still identifies a real vendor, so it is stronger evidence than a bare
        /// folder name — reported by default, but never bulk-selectable.
        return .orphaned(Self.hasTeamIDPrefix(component) ? .vendorLineage : .nameOnly)
    }

    /// A human-friendly app name for grouping, derived from a leftover basename.
    ///
    /// - Parameter component: The basename found on disk.
    /// - Returns: The vendor/product name to show as a group header.
    static func displayName(fromComponent component: String) -> String {
        guard let bundleID = bundleID(fromComponent: component) else { return component }
        let labels = bundleID.split(separator: ".").map(String.init)

        /// Prefer the last meaningful label (`com.digidna.imazing3mac` → `imazing3mac`),
        /// falling back to the vendor label when the leaf is a generic suffix.
        let genericLeaves: Set<String> = ["app", "mac", "macos", "helper", "osx"]
        let meaningful = labels.dropFirst().last(where: { !genericLeaves.contains($0) })
        let chosen = meaningful ?? labels.last ?? bundleID

        /// Restore the original casing from the source component where possible —
        /// "iMazing3Mac" reads better than "imazing3mac".
        if let range = component.lowercased().range(of: chosen) {
            return String(component[range])
        }
        return chosen.capitalized
    }
}
