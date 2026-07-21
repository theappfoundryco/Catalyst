//
//  SnapshotViewModel.swift
//  Catalyst
//
//  Drives the CatalystSnapshot screen: capture → preview → export, and
//  import → diff → (dry-run) → restore. Keeps streaming output isolated in a
//  `ConsoleOutput` (Formrules 3.7) so restore chatter re-renders only the console.
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// The real installers Migrate can drive so it becomes the one place that resolves
/// a fresh Mac — no trip to the Dashboard. Wired in `AppViewModel` to the Dashboard's
/// Homebrew/CLT installers and a `PythonManager`, injected so the VM stays decoupled
/// and testable.
struct PrerequisiteInstaller {
    /// Installs Homebrew (interactive password prompt). Returns whether Homebrew is
    /// present afterwards.
    var installHomebrew: @MainActor () async -> Bool
    /// Triggers Apple's Command Line Tools installer. Can't be awaited to completion —
    /// it hands off to the OS dialog.
    var installCLT: @MainActor () async -> Void
    /// Installs `python@<major.minor>` via Homebrew. Returns success.
    var installPython: @MainActor (_ majorMinor: String) async -> Bool
    /// Invalidate caches + reload every VM after installs, so the re-plan and the
    /// rest of the app reflect the freshly-installed tools.
    var refreshDetection: @MainActor () async -> Void
}

/// Buffers streamed restore output and hands the app-wide `Logger` whole lines.
///
/// The process runner flushes partial chunks (~every 0.1s), and logging those raw
/// would shred single console lines across many timestamped log entries. Buffering
/// to newline boundaries keeps the Logs screen readable, and — because `Logger`
/// writes to disk on its own serial queue — costs the restore loop nothing.
@MainActor
private final class SnapshotLogForwarder {
    private var buffer = ""

    func forward(_ chunk: String) {
        buffer += chunk
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<nl]).trimmingCharacters(in: .whitespaces)
            buffer = String(buffer[buffer.index(after: nl)...])
            guard !line.isEmpty else { continue }
            Logger.shared.log(line, category: .terminal)
        }
    }

    /// Emit any trailing text that never got its newline (end of a run).
    func flush() {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard !rest.isEmpty else { return }
        Logger.shared.log(rest, category: .terminal)
    }
}

enum PrereqKind: Equatable {
    case commandLineTools, homebrew, python(String)
}

/// One missing prerequisite surfaced at the top of Migrate.
struct MissingPrereq: Identifiable, Equatable {
    let kind: PrereqKind
    let title: String
    let detail: String
    var id: String {
        switch kind {
        case .commandLineTools: return "clt"
        case .homebrew: return "homebrew"
        case .python(let mm): return "python.\(mm)"
        }
    }
}

@MainActor
final class SnapshotViewModel: ObservableObject {

    // Busy / phase
    @Published var isWorking = false
    @Published var workingLabel = ""
    /// True only while reading + diffing an imported snapshot. Selects the import
    /// artwork/label on the full-window working view (capture uses the camera one),
    /// so "Reading snapshot" / "Diffing this Mac" gets the same full-screen
    /// treatment as "Capture this Mac" rather than a strip of chrome over the plan.
    @Published var isImporting = false

    // Capture → export
    @Published var capturedSnapshot: CatalystSnapshot?
    @Published var lastExportURL: URL?

    /// Passphrase for sealing API secrets into a capture. Held in memory only — never
    /// persisted, logged, or written anywhere but the derived key. Blank = capture
    /// without secrets (the default).
    ///
    /// Asked for in a sheet at the moment Capture is clicked, rather than a card on
    /// the landing page — that card was easy to scroll past, so people captured
    /// without ever noticing the option existed.
    @Published var capturePassphrase = ""
    @Published var isShowingCaptureSheet = false

    // Import → restore
    @Published var loadedSnapshot: CatalystSnapshot?
    @Published var actions: [RestoreAction] = [] { didSet { rebuildActionIndex() } }
    @Published var summary: RestoreSummary?

    /// Passphrase supplied at restore time to open a snapshot's sealed secrets.
    /// Wrong or empty simply skips that one row.
    @Published var restorePassphrase = "" {
        didSet { if restorePassphrase != oldValue { secretsValidation = .idle } }
    }

    /// Result of the explicit Validate check. Because AES-GCM is authenticated this
    /// is a definitive answer, not a guess — so the user finds out BEFORE running a
    /// restore, instead of discovering it in the results.
    enum SecretsValidation: Equatable {
        case idle, checking
        case valid(Int)
        case invalid
    }
    @Published var secretsValidation: SecretsValidation = .idle

    /// Catalyst placeholders still sitting in `~/.zshrc` — i.e. secrets that were
    /// captured but never unlocked. Drives the standalone "unlock" card so the app
    /// surfaces the unfinished work instead of relying on the user to remember it.
    @Published var pendingSecretPlaceholders = 0

    /// A snapshot opened purely to unlock its secrets (standalone flow) — never
    /// diffed, never planned, never restored.
    @Published var unlockSnapshot: CatalystSnapshot?
    @Published var unlockPassphrase = "" {
        didSet { if unlockPassphrase != oldValue { unlockValidation = .idle } }
    }
    @Published var unlockValidation: SecretsValidation = .idle
    @Published var unlockResult: String?
    @Published var isShowingUnlockSheet = false

    /// Prerequisites this Mac is missing for the loaded snapshot (CLT / Homebrew /
    /// Python interpreters). Drives the "Install All" card at the top of Migrate.
    @Published var missingPrereqs: [MissingPrereq] = []

    /// Injected by `AppViewModel`; nil in contexts without the Dashboard installers.
    var prerequisiteInstaller: PrerequisiteInstaller?

    /// Restore flow phase: `false` = Preview (review + toggles), `true` = Status
    /// (progress + per-item results). Flipped by `runRestore`; reset by `backToPreview`.
    @Published var isShowingStatus = false

    @Published var errorMessage: String?

    /// Accent for the full-screen working view — green while capturing/exporting,
    /// blue while importing/restoring — so each flow stays color-consistent.
    @Published var workingTint: Color = .blue

    /// Isolated streaming console (observed only by `ConsoleOutputView`).
    let console = ConsoleOutput()

    private let capture = SnapshotCaptureService()
    private let differ = SnapshotDiffer()
    private let restore = SnapshotRestoreService()
    private let secrets = SnapshotSecretsService.shared
    private var cancelRequested = false
    private let logger = Logger.shared
    /// Mirrors restore/capture output into the app-wide Logger so Snapshot & Migrate
    /// runs show up on the Logs screen like every other long-running operation.
    /// Previously this output existed only in the run card's console and vanished
    /// with the plan — which is why the Logs screen looked empty for migrations.
    private let logStream = SnapshotLogForwarder()
    /// Timestamp of the last published in-flight sub-status, for throttling.
    private var lastProgressPublish = Date.distantPast

    // MARK: - Derived

    var hasCapture: Bool { capturedSnapshot != nil }
    var hasPlan: Bool { loadedSnapshot != nil }

    /// Counts are CACHED, not recomputed per read.
    ///
    /// These five used to be computed properties, each running a `filter` (an O(n)
    /// pass **plus an array allocation**) over every action. SwiftUI reads all of
    /// them on every body evaluation, and a restore re-evaluates the body on every
    /// status update — so a 300-action plan was doing ~1500 allocating passes per
    /// second. That was the restore-time UI stutter. Now one non-allocating pass
    /// recomputes them when `actions` actually changes.
    private(set) var actionableCount = 0
    private(set) var satisfiedCount = 0
    private(set) var blockedCount = 0
    private(set) var runTotal = 0
    private(set) var runDone = 0

    var progressFraction: Double { runTotal > 0 ? Double(runDone) / Double(runTotal) : 0 }

    /// `id → index` so a status update is a dictionary hit instead of a linear scan
    /// of every action. Rebuilt only when the set of actions changes (a status or
    /// selection mutation keeps the same ids in the same order).
    private var actionIndex: [UUID: Int] = [:]

    private static let terminalStates: Set<RestoreStatus> = [.succeeded, .failed, .partial, .skipped]

    /// Index lookup with a self-healing fallback: a re-plan can produce a
    /// same-length array of entirely new ids, so a cached hit is verified before
    /// use and the map is rebuilt if it's gone stale.
    private func index(of id: UUID) -> Int? {
        if let i = actionIndex[id], i < actions.count, actions[i].id == id { return i }
        actionIndex = Dictionary(uniqueKeysWithValues: actions.enumerated().map { ($0.element.id, $0.offset) })
        return actionIndex[id]
    }

    private func rebuildActionIndex() {
        if actionIndex.count != actions.count { actionIndex.removeAll(keepingCapacity: true) }
        var actionable = 0, satisfied = 0, blocked = 0, total = 0, done = 0
        for a in actions {
            if a.alreadySatisfied { satisfied += 1 }
            if a.blockedReason != nil { blocked += 1 }
            guard a.isActionable, a.selected else { continue }
            actionable += 1
            total += 1
            if Self.terminalStates.contains(a.status) { done += 1 }
        }
        actionableCount = actionable
        satisfiedCount = satisfied
        blockedCount = blocked
        runTotal = total
        runDone = done
    }

    /// Actions grouped in restore order for the sectioned preview.
    var groupedActions: [(kind: SnapshotSectionKind, items: [RestoreAction])] {
        SnapshotSectionKind.restoreOrder.compactMap { kind in
            let items = actions.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items)
        }
    }

    // MARK: - Capture

    /// Ask about encryption first — the sheet is the one moment the choice is
    /// unmissable and still actionable.
    func beginCapture() {
        guard !isWorking else { return }
        capturePassphrase = ""
        isShowingCaptureSheet = true
    }

    func captureThisMac() async {
        guard !isWorking else { return }
        isShowingCaptureSheet = false
        workingTint = .green
        beginWork("Scanning this Mac…")
        defer { endWork() }
        let passphrase = capturePassphrase
        clearAll()
        let snap = await capture.capture(secretsPassphrase: passphrase.isEmpty ? nil : passphrase)
        capturedSnapshot = snap
        // Clear the passphrase from memory the moment it's been used — it's already
        // baked into the derived key, and there's no reason to hold it longer.
        capturePassphrase = ""
        logger.log("📸 Captured snapshot: \(snap.inventory.map { "\($0.kind.rawValue):\($0.count)" }.joined(separator: ", "))"
                   + (snap.secrets.map { " · \($0.count) encrypted secret(s)" } ?? ""),
                   category: .terminal)
    }

    func export() async {
        guard let snapshot = capturedSnapshot else { return }
        let panel = NSSavePanel()
        panel.title = "Export Catalyst Snapshot"
        panel.prompt = "Export"
        panel.nameFieldStringValue = defaultFileName()
        if let type = UTType(filenameExtension: SnapshotSchema.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.message = "This file contains environment metadata and public config only — no passwords, tokens, or private keys."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        beginWork("Writing snapshot…")
        defer { endWork() }
        do {
            try await SnapshotArchiver.write(snapshot, to: url)
            // Stamp the branded document icon directly onto the file. The `.catalystsnapshot`
            // type icon (Info.plist CFBundleTypeIconFile) only shows once Launch Services has
            // registered the app — unreliable for a freshly-exported file — so we set a per-file
            // custom icon here. That makes Finder show the rounded Catalyst doc icon immediately
            // on export, and the file carries it when re-imported elsewhere.
            if let iconURL = Bundle.main.url(forResource: "CatalystSnapshotDoc", withExtension: "icns"),
               let icon = NSImage(contentsOf: iconURL) {
                NSWorkspace.shared.setIcon(icon, forFile: url.path, options: [])
            }
            lastExportURL = url
            logger.log("✅ Snapshot exported to \(url.lastPathComponent)", category: .terminal)
        } catch {
            errorMessage = error.localizedDescription
            logger.log("❌ Snapshot export failed: \(error.localizedDescription)", category: .terminal)
        }
    }

    func discardCapture() {
        capturedSnapshot = nil; lastExportURL = nil
        capturePassphrase = ""
    }

    // MARK: - Import / plan

    func importSnapshot() async {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Catalyst Snapshot"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // Restrict strictly to our bundle extension (a zip under the hood).
        if let type = UTType(filenameExtension: SnapshotSchema.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        workingTint = .blue
        isImporting = true
        beginWork("Reading snapshot…")
        defer { isImporting = false; endWork() }
        clearAll()
        do {
            let snapshot = try await SnapshotArchiver.read(from: url)
            loadedSnapshot = snapshot
            workingLabel = "Diffing this Mac…"
            actions = await differ.plan(for: snapshot)
            await refreshMissingPrereqs()
            logger.log("📂 Loaded snapshot from \(url.lastPathComponent): \(actions.count) planned actions",
                       category: .terminal)
        } catch {
            errorMessage = error.localizedDescription
            logger.log("❌ Snapshot import failed: \(error.localizedDescription)", category: .terminal)
        }
    }

    func discardPlan() {
        loadedSnapshot = nil; actions = []; summary = nil; console.clear()
        isShowingStatus = false; missingPrereqs = []
        restorePassphrase = ""; secretsValidation = .idle; unlockResult = nil
    }

    /// Whether the loaded snapshot carries sealed secrets (drives the passphrase
    /// prompt on the restore screen).
    var sealedSecretCount: Int? { loadedSnapshot?.secrets?.count }

    // MARK: - Encrypted secrets

    /// Check the Migrate passphrase without restoring anything.
    func validateRestorePassphrase() async {
        guard let sealed = loadedSnapshot?.secrets, !restorePassphrase.isEmpty else {
            secretsValidation = .idle
            return
        }
        secretsValidation = .checking
        let count = await secrets.validate(sealed, passphrase: restorePassphrase)
        // The field may have been edited while PBKDF2 was running; that edit already
        // reset the state, so don't stamp a stale result over it.
        guard case .checking = secretsValidation else { return }
        secretsValidation = count.map { .valid($0) } ?? .invalid
    }

    /// Re-apply secrets for the currently loaded snapshot without re-running the
    /// restore. Used by the Apply button that stays available after a run — the
    /// step is idempotent and touches nothing but placeholder lines.
    func applySecretsNow() async {
        guard let sealed = loadedSnapshot?.secrets, !isWorking else { return }
        beginWork("Applying secrets…")
        defer { endWork() }
        let outcome = await secrets.apply(sealed, passphrase: restorePassphrase)
        unlockResult = outcome.message
        await refreshPendingSecrets()
        logger.log("🔐 Apply secrets: \(outcome.message)", category: .terminal)
    }

    /// Recount the placeholders left in `~/.zshrc`.
    func refreshPendingSecrets() async {
        pendingSecretPlaceholders = secrets.pendingPlaceholderCount()
    }

    // MARK: Standalone unlock (no import, no diff, no restore)

    /// Open a snapshot purely to unlock its secrets. This is the escape hatch for
    /// "I skipped the passphrase and later remembered it" — it costs three clicks
    /// instead of a second trip through the whole Migrate journey.
    func beginStandaloneUnlock() async {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Catalyst Snapshot"
        panel.prompt = "Open"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: SnapshotSchema.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.allowsOtherFileTypes = false
        panel.message = "Pick the snapshot these secrets were captured into."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        unlockPassphrase = ""; unlockValidation = .idle; unlockResult = nil
        beginWork("Reading snapshot…")
        defer { endWork() }
        do {
            let snap = try await SnapshotArchiver.read(from: url)
            guard snap.secrets != nil else {
                errorMessage = "That snapshot doesn't contain any encrypted secrets."
                return
            }
            unlockSnapshot = snap
            isShowingUnlockSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func validateUnlockPassphrase() async {
        guard let sealed = unlockSnapshot?.secrets, !unlockPassphrase.isEmpty else {
            unlockValidation = .idle
            return
        }
        unlockValidation = .checking
        let count = await secrets.validate(sealed, passphrase: unlockPassphrase)
        guard case .checking = unlockValidation else { return }
        unlockValidation = count.map { .valid($0) } ?? .invalid
    }

    func applyStandaloneUnlock() async {
        guard let sealed = unlockSnapshot?.secrets, !isWorking else { return }
        beginWork("Applying secrets…")
        defer { endWork() }
        let outcome = await secrets.apply(sealed, passphrase: unlockPassphrase)
        unlockResult = outcome.message
        await refreshPendingSecrets()
        logger.log("🔐 Standalone unlock: \(outcome.message)", category: .terminal)
        if case .applied = outcome {
            unlockPassphrase = ""
            isShowingUnlockSheet = false
            unlockSnapshot = nil
        }
    }

    func dismissUnlockSheet() {
        isShowingUnlockSheet = false
        unlockSnapshot = nil
        unlockPassphrase = ""
        unlockValidation = .idle
    }

    /// Return from the Status screen to the Preview screen (keeps per-item results
    /// so a re-run picks up where it left off).
    func backToPreview() { isShowingStatus = false }

    // MARK: - Prerequisites (Migrate resolves a fresh Mac itself)

    /// Recompute which prerequisites this Mac is missing for the loaded snapshot.
    /// Reuses the same live checks the diff/restore use (`SnapshotUtil`,
    /// `BrewPathManager`, `LocalEnvironment`), so the list stays truthful.
    func refreshMissingPrereqs() async {
        guard let snap = loadedSnapshot else { missingPrereqs = []; return }
        var out: [MissingPrereq] = []

        // Command Line Tools — needed by the Git identity restore.
        if let git = snap.git, !git.isEmpty, !(await SnapshotUtil.commandLineToolsInstalled()) {
            out.append(MissingPrereq(kind: .commandLineTools, title: "Command Line Tools",
                                     detail: "Needed for Git — opens Apple's installer."))
        }
        // Homebrew — needed by brew formulae/casks or any brew-sourced Python.
        let needsBrew = (snap.brew.map { !$0.isEmpty } ?? false)
            || (snap.python?.contains { $0.source == "brew" } ?? false)
        if needsBrew, !(await BrewPathManager.shared.isInstalled) {
            out.append(MissingPrereq(kind: .homebrew, title: "Homebrew",
                                     detail: "Unblocks Homebrew formulae, casks, and Python installs."))
        }
        // Python interpreters the snapshot needs that aren't on this Mac yet.
        let localMMs = Set(await LocalEnvironment.interpreters().map { $0.majorMinor })
        let neededMMs = Set((snap.python ?? [])
            .filter { $0.source == "brew" }
            .map { SnapshotUtil.majorMinor($0.version) })
            .subtracting(localMMs)
        for mm in neededMMs.sorted() {
            out.append(MissingPrereq(kind: .python(mm), title: "Python \(mm)",
                                     detail: "Restores its pip packages."))
        }
        missingPrereqs = out
    }

    /// One-click bootstrap: install everything the snapshot needs, in dependency
    /// order (Homebrew → Python; CLT last and only if Homebrew's installer didn't
    /// already bring it), then re-plan so blocked items become runnable.
    ///
    /// Homebrew and Python are awaited to completion; Command Line Tools hands off to
    /// Apple's own installer dialog, so its items unblock once the user finishes that
    /// and re-imports/re-runs.
    func installPrerequisites() async {
        guard !isWorking, let installer = prerequisiteInstaller, let snap = loadedSnapshot else { return }
        workingTint = .blue
        beginWork("Installing prerequisites…")
        defer { endWork() }

        if missingPrereqs.contains(where: { $0.kind == .homebrew }) {
            _ = await installer.installHomebrew()
        }
        var installedPython = false
        for p in missingPrereqs {
            if case .python(let mm) = p.kind {
                _ = await installer.installPython(mm)
                installedPython = true
            }
        }
        if missingPrereqs.contains(where: { $0.kind == .commandLineTools }),
           !(await SnapshotUtil.commandLineToolsInstalled()) {
            await installer.installCLT()
        }

        // Let brew's just-created python symlinks settle before the rescan (mirrors
        // the Dashboard's post-install wait) — otherwise the live `bin/` scan in the
        // re-plan can miss a freshly installed interpreter and it still shows "missing."
        if installedPython { try? await Task.sleep(for: .seconds(2)) }

        // Invalidate caches + reload every VM so the re-plan sees the new tools and
        // the rest of the app (Dashboard, Python screens) reloads nicely too.
        await installer.refreshDetection()

        // Re-plan against the now-updated Mac + refresh the missing list.
        actions = await differ.plan(for: snap)
        await refreshMissingPrereqs()
        logger.log("🧩 Prerequisites step done — \(missingPrereqs.count) still missing, \(actions.count) actions")
    }

    // MARK: - Selection

    func setSelected(_ id: UUID, _ value: Bool) {
        guard let i = index(of: id), actions[i].selected != value else { return }
        actions[i].selected = value
    }

    func setSection(_ kind: SnapshotSectionKind, selected: Bool) {
        for i in actions.indices where actions[i].kind == kind { actions[i].selected = selected }
    }

    // MARK: - Apply

    func runRestore() async {
        guard !isWorking, loadedSnapshot != nil else { return }
        cancelRequested = false
        summary = nil
        console.clear()
        isShowingStatus = true          // move to the Status screen
        beginWork("Restoring…")
        defer { endWork() }

        // Reset transient status on selected actionable rows.
        for i in actions.indices where actions[i].isActionable && actions[i].selected {
            actions[i].status = .pending
            actions[i].message = nil
        }

        let result = await restore.apply(
            snapshot: loadedSnapshot!,
            actions: actions,
            dryRun: false,
            onOutput: { [weak self] chunk in
                self?.console.append(chunk)
                self?.logStream.forward(chunk)
            },
            onUpdate: { [weak self] id, status, message in
                guard let self, let i = self.index(of: id) else { return }
                // Sub-status chatter while an action is still running (pip pushes one
                // per package) is throttled: it changes only a caption, but each
                // mutation republishes `actions` and re-renders the plan. Terminal
                // states always go through immediately — those move the progress bar.
                if status == .running && self.actions[i].status == .running {
                    let now = Date()
                    guard now.timeIntervalSince(self.lastProgressPublish) > 0.2 else { return }
                    self.lastProgressPublish = now
                }
                if self.actions[i].status != status { self.actions[i].status = status }
                if let message, self.actions[i].message != message { self.actions[i].message = message }
            },
            shouldContinue: { [weak self] in !(self?.cancelRequested ?? true) },
            secretsPassphrase: restorePassphrase.isEmpty ? nil : restorePassphrase
        )
        logStream.flush()
        // Recount placeholders so the "still sealed" affordance appears immediately
        // if the passphrase was skipped or wrong.
        await refreshPendingSecrets()
        summary = result
        logger.log("🧩 Restore done: \(result.succeeded) ok / \(result.partial) partial / \(result.failed) failed / \(result.skipped) skipped",
                   category: .terminal)
    }

    func cancel() { cancelRequested = true }

    // MARK: - Helpers

    private func beginWork(_ label: String) { isWorking = true; workingLabel = label; errorMessage = nil }
    private func endWork() { isWorking = false; workingLabel = "" }
    private func clearAll() {
        capturedSnapshot = nil; lastExportURL = nil
        loadedSnapshot = nil; actions = []; summary = nil; missingPrereqs = []
    }

    private func defaultFileName() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let host = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .components(separatedBy: CharacterSet(charactersIn: " .")).first ?? "Mac"
        return "\(host)-\(df.string(from: Date())).\(SnapshotSchema.fileExtension)"
    }
}
