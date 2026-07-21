import Foundation
import SwiftUI
import Combine

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

    /// Recompute all `issues`-derived values once per change. Previously each of
    /// these was a computed property filtering `issues` inside `body`, so a view
    /// that read several of them did many array passes per render (R3).
    private func recomputeDerived() {
        criticalCount = issues.filter { $0.severity == .critical }.count
        warningCount = issues.filter { $0.severity == .warning }.count
        infoCount = issues.filter { $0.severity == .info }.count
        liveMetrics = DrLiveMetrics(issues: issues)
    }

    init() {
        refreshHistory()
    }
    
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
    
    private func refreshHistory() {
        history = historyStore.loadHistory()
        if let last = history.last {
            currentScore = last.score
        }
    }
}
