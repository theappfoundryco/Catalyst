import Foundation

/// Execution half of Orphanage: moves leftovers into a Catalyst-owned staging
/// directory, restores them on demand, purges them once the grace period lapses,
/// and records every action to an on-disk audit log.
///
/// Nothing here deletes on the spot. A "delete" is a **move** to
/// `~/Library/Application Support/Catalyst/Quarantine`, which sits on the same
/// volume as `~/Library` and is therefore an atomic rename — it cannot half-apply,
/// and it is fully reversible for 30 days.
///
/// ```swift
/// let service = OrphanCleanupService()
/// let outcome = await service.quarantine(items, appName: "iMazing")
/// ```
actor OrphanCleanupService {

    /// What a quarantine run produced.
    struct Outcome: Sendable {
        /// Items successfully staged.
        var quarantined: [QuarantineRecord] = []
        /// Paths skipped, with the reason (re-verified as owned, file in use, …).
        var skipped: [(path: String, reason: String)] = []
        /// Paths that failed outright.
        var failed: [(path: String, reason: String)] = []

        /// Total bytes reclaimed by this run.
        var reclaimedBytes: Int64 { quarantined.reduce(0) { $0 + $1.size } }
    }

    private let fileManager = FileManager.default
    /// Shared process runner — every shell-out goes through it (CODING_STANDARDS 2.1).
    private let runner = AsyncProcessRunner.shared
    private let logger = Logger.shared
    /// Absolute path, never resolved via `PATH` — CODING_STANDARDS 2.2.
    private let launchctlPath = "/bin/launchctl"
    /// Absolute path, never resolved via `PATH` — CODING_STANDARDS 2.2.
    private let lsofPath = "/usr/sbin/lsof"

    // MARK: - Storage locations

    /// Directory holding staged items.
    private var quarantineRoot: URL { OrphanPathValidator.quarantineRoot() }

    /// JSON manifest of everything currently staged.
    private var manifestURL: URL {
        quarantineRoot.appendingPathComponent("manifest.json")
    }

    /// Append-only JSON audit log.
    private var auditURL: URL {
        quarantineRoot.appendingPathComponent("audit.json")
    }

    /// Creates the staging directory if absent.
    private func ensureQuarantineRoot() throws {
        try fileManager.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
    }

    // MARK: - Quarantine

    /// Moves the given leftovers into quarantine.
    ///
    /// **Flow:**
    /// 1. Rebuild the installed-app index and **re-verify** every item — the user
    ///    may have reinstalled the app between the scan and this confirmation.
    /// 2. Re-run the path allowlist gate (state on disk can have changed too).
    /// 3. Refuse anything currently held open by a running process.
    /// 4. `launchctl bootout` any launch agent before its plist moves.
    /// 5. Move to `Quarantine/<uuid>/<basename>`, then record + audit.
    ///
    /// - Parameters:
    ///   - items: The user's confirmed selection.
    ///   - index: Freshly built installed-app index, passed in from the `@MainActor`
    ///     caller because `NSWorkspace` is main-actor bound.
    /// - Returns: An ``Outcome`` describing what moved, what was skipped, what failed.
    func quarantine(_ items: [LeftoverItem], index: InstalledAppIndex) async -> Outcome {
        var outcome = Outcome()
        let matcher = OrphanMatcher()

        do {
            try ensureQuarantineRoot()
        } catch {
            logger.log("⚠️ Orphanage: could not create quarantine directory")
            outcome.failed = items.map { ($0.path, "Quarantine directory unavailable") }
            return outcome
        }

        for item in items {
            /// System-scope items need the privileged helper, which does not exist
            /// as a build target yet. They are never actionable in Phase 1.
            guard item.isActionable else {
                outcome.skipped.append((item.path, "Needs administrator privileges"))
                continue
            }

            /// RE-VERIFY OWNERSHIP. The scan may be minutes old; a reinstall in the
            /// meantime must cancel the delete rather than wipe the fresh install's
            /// data.
            let component = item.url.lastPathComponent
            if case .owned = matcher.classify(component: component, against: index) {
                outcome.skipped.append((item.path, "App is installed again — left in place"))
                await appendAudit(.init(action: .failed, path: item.path, size: item.size,
                                   detail: "skipped: owner reappeared"))
                continue
            }

            /// RE-VERIFY THE PATH. Cheap, and the only gate standing between a
            /// logic bug and a Library subtree.
            guard OrphanPathValidator.isEligible(item.url) else {
                outcome.skipped.append((item.path, "Path is outside the permitted areas"))
                continue
            }

            guard fileManager.fileExists(atPath: item.path) else {
                outcome.skipped.append((item.path, "No longer on disk"))
                continue
            }

            /// Refuse anything a running process still holds open — moving it would
            /// corrupt live state.
            if await isInUse(item.url) {
                outcome.skipped.append((item.path, "In use by a running process"))
                continue
            }

            /// A launch agent must be booted out first. Deleting the plist while the
            /// job is loaded leaves launchd still tracking it.
            if item.category == .userLaunchAgent {
                await unloadAgent(at: item.url)
            }

            do {
                let record = try move(item)
                outcome.quarantined.append(record)
                await appendAudit(.init(action: .quarantined, path: item.path, size: item.size,
                                   detail: item.category.rawValue))
            } catch {
                outcome.failed.append((item.path, "Move failed"))
                await appendAudit(.init(action: .failed, path: item.path, size: item.size,
                                   detail: "move failed"))
            }
        }

        if !outcome.quarantined.isEmpty {
            var manifest = loadManifest()
            manifest.append(contentsOf: outcome.quarantined)
            saveManifest(manifest)
        }

        logger.log("🗃 Orphanage: quarantined \(outcome.quarantined.count), skipped \(outcome.skipped.count), failed \(outcome.failed.count)")
        return outcome
    }

    /// Performs the staging move for one item.
    ///
    /// Each record gets its own UUID subdirectory so two apps with identically
    /// named leftovers (`Caches/Logs`) never collide in the staging area.
    private func move(_ item: LeftoverItem) throws -> QuarantineRecord {
        let recordID = UUID()
        let destinationDirectory = quarantineRoot.appendingPathComponent(recordID.uuidString)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let destination = destinationDirectory.appendingPathComponent(item.url.lastPathComponent)
        try fileManager.moveItem(at: item.url, to: destination)

        return QuarantineRecord(
            id: recordID,
            originalPath: item.path,
            quarantinePath: destination.path,
            category: item.category,
            size: item.size,
            appName: item.appName,
            bundleID: item.bundleID,
            quarantinedAt: Date()
        )
    }

    // MARK: - Restore

    /// Puts a quarantined item back at its original path.
    ///
    /// - Parameter record: The manifest entry to restore.
    /// - Returns: `true` when the item is back in place.
    @discardableResult
    func restore(_ record: QuarantineRecord) async -> Bool {
        let source = URL(fileURLWithPath: record.quarantinePath)
        let destination = URL(fileURLWithPath: record.originalPath)

        guard fileManager.fileExists(atPath: source.path) else {
            logger.log("⚠️ Orphanage: quarantined item missing, dropping manifest entry")
            removeFromManifest(record.id)
            return false
        }

        /// Never overwrite something that has since reappeared at the original
        /// path — a reinstall's fresh data outranks our stale copy.
        guard !fileManager.fileExists(atPath: destination.path) else {
            logger.log("⚠️ Orphanage: restore target already exists, leaving quarantined")
            return false
        }

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: source, to: destination)
            try? fileManager.removeItem(at: source.deletingLastPathComponent())
            removeFromManifest(record.id)
            await appendAudit(.init(action: .restored, path: record.originalPath,
                                    size: record.size, detail: record.appName))
            return true
        } catch {
            logger.log("⚠️ Orphanage: restore failed for \(record.appName)")
            await appendAudit(.init(action: .failed, path: record.originalPath,
                                    size: record.size, detail: "restore failed"))
            return false
        }
    }

    // MARK: - Purge

    /// Permanently removes staged items whose grace period has lapsed.
    ///
    /// **Gotchas:** Expiry alone is not sufficient grounds to purge. If the owning
    /// app was reinstalled during the grace period, its data is wanted again — the
    /// record is held back and reported so the UI can offer a restore instead.
    ///
    /// - Parameter index: A freshly built installed-app index.
    /// - Returns: The records held back because their app came back.
    @discardableResult
    func purgeExpired(index: InstalledAppIndex) async -> [QuarantineRecord] {
        let manifest = loadManifest()
        guard !manifest.isEmpty else { return [] }

        let matcher = OrphanMatcher()
        var remaining: [QuarantineRecord] = []
        var reappeared: [QuarantineRecord] = []

        for record in manifest {
            guard record.daysRemaining == 0 else {
                remaining.append(record)
                continue
            }

            let component = URL(fileURLWithPath: record.originalPath).lastPathComponent
            if case .owned = matcher.classify(component: component, against: index) {
                reappeared.append(record)
                remaining.append(record)
                continue
            }

            let staged = URL(fileURLWithPath: record.quarantinePath)
            do {
                try fileManager.removeItem(at: staged.deletingLastPathComponent())
                await appendAudit(.init(action: .purged, path: record.originalPath,
                                        size: record.size, detail: record.appName))
            } catch {
                remaining.append(record)
                await appendAudit(.init(action: .failed, path: record.originalPath,
                                        size: record.size, detail: "purge failed"))
            }
        }

        saveManifest(remaining)
        if !reappeared.isEmpty {
            logger.log("↩️ Orphanage: \(reappeared.count) quarantined item(s) held back — app reinstalled")
        }
        return reappeared
    }

    // MARK: - Process and launchd checks

    /// Whether any running process holds the path (or something beneath it) open.
    ///
    /// **Rationale:** Checked at delete time rather than scan time — running `lsof`
    /// against every candidate during a scan would dominate its cost, and the
    /// answer would be stale by the time the user confirmed anyway.
    private func isInUse(_ url: URL) async -> Bool {
        do {
            let result = try await runner.run(
                executable: lsofPath,
                arguments: ["-nP", "--", url.path],
                timeoutSeconds: 6
            )
            /// `lsof` exits non-zero when nothing has the path open, which is the
            /// common case — decide on exit code, never by scraping stdout
            /// (CODING_STANDARDS 2.4).
            return result.succeeded && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            /// If the check itself fails we cannot prove the path is free, so treat
            /// it as in use and leave the item alone.
            logger.log("⚠️ Orphanage: could not check open handles, skipping item")
            return true
        }
    }

    /// Boots a launch agent out of launchd before its plist is quarantined.
    ///
    /// **Gotchas:** Removing the plist without unloading leaves the job registered
    /// — `launchctl list` keeps reporting it with a `-` PID until it is booted out.
    /// `bootout gui/<uid>/<label>` is the modern spelling of what
    /// `LoginItemsService.removeAgent` does with `unload -w`.
    private func unloadAgent(at url: URL) async {
        guard let label = agentLabel(at: url) else { return }
        let uid = getuid()
        do {
            let result = try await runner.run(
                executable: launchctlPath,
                arguments: ["bootout", "gui/\(uid)/\(label)"],
                timeoutSeconds: 8
            )
            /// A job that was not loaded returns non-zero — that is a no-op, not a
            /// failure worth surfacing.
            if result.succeeded {
                await appendAudit(.init(action: .unloadedAgent, path: url.path, size: 0, detail: label))
            }
        } catch {
            logger.log("⚠️ Orphanage: launchctl bootout failed for an agent")
        }
    }

    /// Reads the `Label` key out of a launchd plist.
    private func agentLabel(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return nil }
        return plist["Label"] as? String
    }

    // MARK: - Manifest persistence

    /// Reads the staged-item manifest, returning empty on any decode problem.
    func loadManifest() -> [QuarantineRecord] {
        guard let data = try? Data(contentsOf: manifestURL),
              let records = try? JSONDecoder().decode([QuarantineRecord].self, from: data)
        else { return [] }
        return records
    }

    /// Writes the manifest back to disk.
    private func saveManifest(_ records: [QuarantineRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? ensureQuarantineRoot()
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// Drops one entry from the manifest.
    private func removeFromManifest(_ id: UUID) {
        saveManifest(loadManifest().filter { $0.id != id })
    }

    // MARK: - Audit log

    /// Appends one entry to the audit log.
    ///
    /// Records paths, sizes, timestamps and action outcomes only. Never command
    /// output or anything credential-shaped (CODING_STANDARDS 2.10).
    private func appendAudit(_ entry: OrphanAuditEntry) async {
        var entries = loadAuditLog()
        entries.append(entry)
        /// Bounded so a heavy user cannot grow this without limit.
        if entries.count > 2000 { entries.removeFirst(entries.count - 2000) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? ensureQuarantineRoot()
        try? data.write(to: auditURL, options: .atomic)
    }

    /// Reads the audit log, newest last.
    func loadAuditLog() -> [OrphanAuditEntry] {
        guard let data = try? Data(contentsOf: auditURL),
              let entries = try? JSONDecoder().decode([OrphanAuditEntry].self, from: data)
        else { return [] }
        return entries
    }
}
