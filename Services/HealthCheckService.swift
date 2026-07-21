import Foundation

/// A centralized orchestrator that executes comprehensive system-wide diagnostic scans.
///
/// `HealthCheckService` runs every `Doctor` in a single array, aggregates their
/// issues, and derives both the per-category status and auto-fix routing from that
/// one source of truth — no per-module wiring in multiple places.
final class HealthCheckService {
    /// The shared singleton instance.
    static let shared = HealthCheckService()

    /// Every diagnostic module. Adding a doctor is a one-line change here.
    /// Order is cosmetic; statuses are emitted in `HealthCategory.allCases` order.
    private let doctors: [Doctor] = [
        ShellIntegrityCheck(),
        PathSanityCheck(),
        ToolChainCheck(),
        PermissionsCheck(),
        NetworkDoctor(),
        DiskHygieneDoctor(),
        ConflictDoctor(),
        GitDoctor(),
        SecurityDoctor(),
        ArchitectureDoctor(),
        FirewallDoctor(),
        StartupDoctor(),
        MemoryDoctor(),
        ContainerDoctor(),
        JavaDoctor(),
        NodeDoctor()
    ]

    private init() {}

    /// Initiates a complete health scan traversing all configured diagnostic modules asynchronously.
    ///
    /// - Returns: A `ScanResult` payload containing the issues found and a status row per category.
    func runFullScan() async -> ScanResult {
        Logger.shared.log("🩺 Dr. Catalyst: Starting full system scan...")

        let doctors = self.doctors
        return await Task.detached {
            // Run every doctor concurrently. Availability-gated doctors
            // (Docker/Java/Node) report unavailable instead of running.
            let runs = await withTaskGroup(of: (HealthCategory, [HealthIssue], Bool).self) { group -> [(HealthCategory, [HealthIssue], Bool)] in
                for doctor in doctors {
                    group.addTask {
                        if let checkable = doctor as? AvailabilityCheckable {
                            if await checkable.checkAvailability() {
                                return (doctor.category, await doctor.run(), true)
                            } else {
                                return (doctor.category, [], false)
                            }
                        } else {
                            return (doctor.category, await doctor.run(), true)
                        }
                    }
                }
                var collected: [(HealthCategory, [HealthIssue], Bool)] = []
                for await result in group { collected.append(result) }
                return collected
            }

            let allIssues = runs.flatMap { $0.1 }
            // Categories whose (only) doctor is an unavailable tool.
            let unavailable = Set(runs.filter { !$0.2 }.map { $0.0 })

            // One status row per category, in stable order.
            var statuses: [DoctorStatus] = []
            for category in HealthCategory.allCases {
                if unavailable.contains(category) {
                    statuses.append(DoctorStatus(category: category, status: .notInstalled(nil)))
                    continue
                }
                let count = allIssues.filter { $0.category == category }.count
                statuses.append(DoctorStatus(category: category, status: count == 0 ? .passed : .failed(count: count)))
            }

            Logger.shared.log("🩺 Dr. Catalyst: Scan complete. Found \(allIssues.count) issues.")
            return ScanResult(issues: allIssues, doctorStatuses: statuses)
        }.value
    }

    /// Routes an auto-fix to whichever doctor owns the issue. Each doctor's `fix`
    /// returns false for issues it doesn't own (matched on `fixID`), so trying them
    /// in turn finds the right one — no category switch, no `.security` double-dispatch.
    ///
    /// - Parameter issue: The corresponding `HealthIssue` to resolve.
    /// - Returns: Whether any doctor successfully applied the fix.
    func fix(issue: HealthIssue) async -> Bool {
        Logger.shared.log("🩺 Dr. Catalyst: Attempting fix for \(issue.title)...")
        for doctor in doctors {
            if await doctor.fix(issue) { return true }
        }
        return false
    }
}
