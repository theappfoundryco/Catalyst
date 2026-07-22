import Foundation
import SwiftUI
import Combine

/// A view model governing the `Dr. Catalyst` diagnostic suite.
///
/// It coordinates parallel health checks (`HealthCheckService`), SSD status scans (`StorageDoctor`),
/// and zombie process checks (`GhostBusterViewModel`), aggregating their results into a unified score.
///
/// ```swift
/// @StateObject var drVM = DrCatalystViewModel()
/// await drVM.scan()
/// print(drVM.currentScore)
/// ```
@MainActor
final class DrCatalystViewModel: ObservableObject {
    @Published var isScanning = false
    // Derived state (counts + LiveMetricsGrid values) is recomputed once here on
    // every change, instead of being filtered out of `issues` on every render of
    // every view that reads it (R3).
    @Published var issues: [HealthIssue] = [] { didSet { recomputeDerived() } }
    @Published var doctorStatuses: [DoctorStatus] = []
    @Published var history: [HealthSnapshot] = []
    @Published var currentScore: Int = 100
    @Published var activeTab: String = "Current"

    // Sub-ViewModels
    @Published var ghostBusterVM = GhostBusterViewModel()

    private let service = HealthCheckService.shared
    private let historyStore = HealthHistoryStore()

    @Published var storageReport: StorageReport? = nil

    // Precomputed derived values (see `recomputeDerived`).
    @Published private(set) var criticalCount = 0
    @Published private(set) var warningCount = 0
    @Published private(set) var infoCount = 0
    @Published private(set) var liveMetrics = DrLiveMetrics()

    /// Recomputes all `issues`-derived values once per state change.
    ///
    /// **Rationale:**
    /// Previously each of these was a computed property filtering `issues` inside `body`. If a View
    /// read several of them, it triggered many full array passes per render. Hoisting them into `@Published`
    /// variables updated in `didSet` cuts CPU overhead dramatically.
    private func recomputeDerived() {
        criticalCount = issues.filter { $0.severity == .critical }.count
        warningCount = issues.filter { $0.severity == .warning }.count
        infoCount = issues.filter { $0.severity == .info }.count
        liveMetrics = DrLiveMetrics(issues: issues)
    }

    /// Initializes ``DrCatalystViewModel`` and eagerly loads historical records from disk.
    init() {
        refreshHistory()
    }
    
    /// Kicks off a parallel scan across the system's environments, SSD, and active ports.
    ///
    /// **Flow:**
    /// 1. Toggles ``isScanning``.
    /// 2. Fires off ``HealthCheckService/runFullScan()``, ``StorageDoctor/scan()``, and ``GhostBusterViewModel/scan()`` concurrently.
    /// 3. Awaits the tuple and pushes results to `@Published` properties.
    /// 4. Flushes the new snapshot to the historical disk store.
    ///
    /// **Caveats:**
    /// - SSD Storage scans run detached off the MainActor because `FileManager` operations block
    ///   synchronously and can freeze the UI when scanning large DerivedData directories.
    func scan() async {
        isScanning = true
        
        // 1. Health Check (Main Actor OK as it uses async processes)
        async let scanResult = service.runFullScan()
        
        // 2. Storage Scan (Detached to avoid Main Thread Block due to FileManager sync calls)
        let storageTask = Task.detached(priority: .userInitiated) {
            return await StorageDoctor().scan()
        }
        
        // 3. Ghost Buster Scan
        async let ghostScan: () = ghostBusterVM.scan()
        
        let (result, report, _) = await (scanResult, storageTask.value, ghostScan)
        
        self.issues = result.issues
        self.doctorStatuses = result.doctorStatuses
        self.storageReport = report
        
        historyStore.saveSnapshot(result.issues)
        refreshHistory()
        
        if let last = history.last {
            currentScore = last.score
        }
        
        isScanning = false
    }
    
    /// Executes the embedded auto-fixer for a given issue, then triggers a re-scan.
    ///
    /// - Parameter issue: The ``HealthIssue`` containing the actionable repair payload.
    func fix(_ issue: HealthIssue) async {
        let success = await service.fix(issue: issue)
        if success {
            Logger.shared.log("✅ Fixed issue: \(issue.title)")
            // Re-scan to update UI
            await scan()
        } else {
            Logger.shared.log("❌ Failed to fix issue: \(issue.title)")
        }
    }
    
    /// Reloads the user's historical snapshot array from disk.
    private func refreshHistory() {
        history = historyStore.loadHistory()
        if let last = history.last {
            currentScore = last.score
        }
    }
}
