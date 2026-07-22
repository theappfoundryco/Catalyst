import SwiftUI
import AppKit
import Sparkle
import Combine

/// Phases surfaced by the sidebar update badge (see `SidebarUpdateBadge` in ContentView).
enum UpdatePhase: Equatable {
    case idle
    case available(version: String)
    case downloading(version: String)
    case readyToRelaunch(version: String)
}

/// Owns the Sparkle updater (P9) and drives a CUSTOM, gentle update UX like the Claude app:
/// updates download silently in the background (`SUAutomaticallyUpdate` in Info.plist), and we
/// surface a small sidebar badge ("Update available" → "Downloading…" → "Relaunch to update")
/// instead of Sparkle's own window. We keep Sparkle's `SPUStandardUserDriver` but adopt its
/// "gentle reminders" hooks to suppress the automatic popup and present our own UI; tapping the
/// "Relaunch to update" badge resumes the standard install-and-relaunch flow.
///
/// Kept in this already-registered file to avoid a new-file pbxproj entry (CODING_STANDARDS §9).
final class UpdaterController: NSObject, ObservableObject,
                               SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = UpdaterController()

    /// Current update phase (drives the sidebar badge).
    @Published private(set) var phase: UpdatePhase = .idle

    private var controller: SPUStandardUpdaterController!
    var updater: SPUUpdater { controller.updater }

    /// Sparkle's "install the already-downloaded update now + relaunch" block, captured when the
    /// silent auto-download finishes (`willInstallUpdateOnQuit`). Calling it installs immediately
    /// with NO Sparkle UI — that's what the "Relaunch to update" badge invokes.
    private var immediateInstall: (() -> Void)?

    private override init() {
        super.init()
        /// startingUpdater: true begins scheduled background checks (interval from Info.plist
        /// SUScheduledCheckInterval). We register ourselves as both delegates.
        ///
        /// **Gotchas:** Failing to start the updater manually prevents Sparkle from reading the `Info.plist` polling interval, effectively disabling all automatic update checks.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)

        /// IRONCLAD silent auto-download (fixes the "Update available" badge that never downloaded
        /// or offered Relaunch — seen in v1.6, still latent since the code was unchanged).
        /// Root cause (verified against the SPUUpdater API docs): our Info.plist sets BOTH
        /// `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate`. Setting `SUEnableAutomaticChecks`
        /// makes Sparkle SKIP the second-launch opt-in prompt — but per the docs that opt-in is the
        /// exact mechanism that applies `SUAutomaticallyUpdate` to the runtime
        /// `automaticallyDownloadsUpdates` property. So it stays at its default (NO). Result: a found
        /// update lights `didFindValidUpdate` (badge → "Update available") but Sparkle then tries to
        /// *show* it via the user driver instead of downloading; our gentle-reminder delegate
        /// suppresses that window, so nothing downloads and the badge is stuck with no "Relaunch".
        ///
        /// Setting these explicitly at launch is the documented way to force always-silent download,
        /// which is our intended product behavior (badge-driven, no Sparkle popup). `allowsAutomaticUpdates`
        /// is honoured internally, so this is a no-op if a build ever disallows it.
        ///
        /// **Rationale:** Prevents Catalyst from becoming permanently stranded on an old version with a stalled UI badge that refuses to download the payload.
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true
    }

    /// Manual silent background check (e.g. for a "Check for Updates" action).
    func checkInBackground() { updater.checkForUpdatesInBackground() }

    /// Iron-clad "check on open" (Claude-style). `startingUpdater: true` only checks at launch when
    /// `SUScheduledCheckInterval` has elapsed since the last check, and defers the first check after
    /// a fresh install — so relying on the scheduler alone means "open the app" frequently checks
    /// nothing. We force one background check shortly after launch. Collision-safe: `canCheckForUpdates`
    /// is false while Sparkle's own launch session is already running, so we only start one when none
    /// is in flight (no `sessionInProgress` churn). On finding an update, `didFindValidUpdate` lights
    /// the sidebar badge immediately, then auto-download drives it to "Relaunch to update".
    /// (Verify `canCheckForUpdates` against the Sparkle 2.x header, per our signing-off ritual.)
    func checkOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.updater.canCheckForUpdates else { return }
            self.updater.checkForUpdatesInBackground()
        }
    }

    /// User tapped the "Relaunch to update" badge. If Sparkle handed us the immediate-install
    /// block (auto-download finished), use it — installs + relaunches with no dialog. Otherwise
    /// fall back to Sparkle's standard check/install flow.
    func relaunchToUpdate() {
        if let install = immediateInstall { install() }
        else { updater.checkForUpdates() }
    }

    // MARK: SPUUpdaterDelegate — drive the badge from the real update lifecycle.

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        DispatchQueue.main.async {
            if case .readyToRelaunch = self.phase { return }   // already downloaded — keep it
            self.phase = .available(version: v)
        }
    }

    /// Intercepts Sparkle's download initiation to inspect the incoming version string.
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem,
                 with request: NSMutableURLRequest) {
        let v = item.displayVersionString
        DispatchQueue.main.async {
            if case .readyToRelaunch = self.phase { return }
            self.phase = .downloading(version: v)
        }
    }

    /// Fires right after the update finishes downloading silently in the background (auto-update).
    /// Returning `true` takes control of installation so we can trigger it on the badge tap with no
    /// Sparkle window; Sparkle still installs on quit if the user never taps. This is the hook that
    /// makes the "Relaunch to update" badge reliable in auto-download mode.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let v = item.displayVersionString
        DispatchQueue.main.async {
            self.immediateInstall = immediateInstallHandler
            self.phase = .readyToRelaunch(version: v)
        }
        return true
    }

    /// Clears the active update phase if Sparkle's background check finds nothing.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async { if self.isTransient { self.phase = .idle } }
    }

    // MARK: SPUStandardUserDriverDelegate — gentle reminders (suppress Sparkle's own window).

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Suppresses Sparkle's default popup window for scheduled checks.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        /// No — we present our own sidebar badge instead of Sparkle's popup.
        ///
        /// **Rationale:** Catalyst enforces a zero-interruption design philosophy; standard Sparkle popups violate this by stealing window focus.
        false
    }

    /// Ensures the custom UI badge stays in sync if Sparkle forces an update window.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        /// Backstop: if Sparkle presents an update we haven't already marked ready, show the badge.
        ///
        /// **Gotchas:** Network race conditions might cause Sparkle to skip `didFindValidUpdate` before presenting; catching it here ensures the UI stays synchronized.
        let v = update.displayVersionString
        DispatchQueue.main.async {
            guard !handleShowingUpdate else { return }
            if case .readyToRelaunch = self.phase { return }
            self.phase = .available(version: v)
        }
    }

    /// Don't clear a "ready to relaunch" badge just because a later no-op check finds nothing.
    private var isTransient: Bool {
        switch phase { case .readyToRelaunch: return false; default: return true }
    }
}

/// The main application entry point defining the UI scene structure.
@main
struct CatalystApp: App {
    @StateObject private var appVM = AppViewModel()

    init() { Telemetry.start() }   // one place a telemetry provider would initialise (currently a no-op)

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .environmentObject(appVM)
                .task {
                    /// Start the Sparkle updater (schedules its own hourly checks) AND force a
                    /// collision-safe check on open so the "Relaunch to update" badge appears
                    /// reliably on launch, not just whenever Sparkle's scheduler next fires.
                    ///
                    /// **Rationale:** Immediate launch checking ensures users who force-quit to grab an update don't wait an hour for the scheduler to wake up.
                    UpdaterController.shared.checkOnLaunch()
                    Telemetry.log(.appOpen)
                    TelemetryProfile.refresh()
                    await appVM.startupChecks()
                }
                // Uncomment the area below if you want to not open in a maxed out window
                // .onAppear {
                //     DispatchQueue.main.async {
                //         if let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? NSApplication.shared.windows.first {
                //             if !window.isZoomed {
                //                 window.zoom(nil)
                //             }
                //         }
                //     }
                // }
        }

        /// Menu-bar mode: health score, outdated count, and quick actions
        /// without opening the main window.
        ///
        /// **Rationale:** Maps directly to Catalyst's role as a pervasive background daemon, surfacing critical system vitals in zero clicks.
        MenuBarExtra("Catalyst", systemImage: "bolt.heart.fill") {
            MenuBarContentView(appVM: appVM)
        }
        .menuBarExtraStyle(.window)
    }
}
