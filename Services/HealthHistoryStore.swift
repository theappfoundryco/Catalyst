import Foundation

/// A local storage registry preserving diagnostic scan aggregations to trace temporal health variations.
///
/// ```swift
/// let store = HealthHistoryStore()
/// store.saveSnapshot(issues)
/// let history = store.loadHistory()
/// ```
struct HealthHistoryStore {
    private let fileURL: URL
    
    /// Establishes the connection parameters mapping straight to the application support storage domains.
    init() {
        let appSupport = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport?.appendingPathComponent("com.shivanggulati.catalyst") ?? FileManager.default.temporaryDirectory
        self.fileURL = dir.appendingPathComponent("health_history.json")
    }
    
    /// Saves a new health snapshot to the local history store based on the active scan results.
    ///
    /// **Gotchas:**
    /// Snapshots are debounced by calendar day. A subsequent save on the exact same day overwrites the existing daily snapshot, preventing automatic remediation sweeps from filling the 30-day capacity in one afternoon.
    ///
    /// - Parameter issues: The array of `HealthIssue` objects detected during the current scan.
    func saveSnapshot(_ issues: [HealthIssue]) {
        let score = calculateScore(issues: issues)
        let critical = issues.filter { $0.severity == .critical }.count
        
        let snapshot = HealthSnapshot(
            date: Date(),
            score: score,
            issueCount: issues.count,
            criticalCount: critical
        )
        
        var history = loadHistory()

        /// Debounce: keep at most one snapshot per calendar day. `fix()` re-scans
        /// after every auto-fix, which previously wrote many snapshots minutes
        /// apart, flooding the chart with redundant data points.
        ///
        /// **Rationale:** Prevents UI thrashing on the frontend charts by enforcing strict daily aggregations of health states.
        if let last = history.last, Calendar.current.isDate(last.date, inSameDayAs: snapshot.date) {
            history[history.count - 1] = snapshot
        } else {
            history.append(snapshot)
        }

        if history.count > 30 {
            history.removeFirst(history.count - 30)
        }

        try? JSONEncoder().encode(history).write(to: fileURL)
    }
    
    /// Retrieves the chronological history of saved health snapshots.
    ///
    /// - Returns: An array of `HealthSnapshot` items sorted by date from oldest to newest.
    func loadHistory() -> [HealthSnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let history = try? JSONDecoder().decode([HealthSnapshot].self, from: data) else {
            return []
        }
        return history.sorted { $0.date < $1.date }
    }
    
    /// Maps the list of active issues into a single score out of 100 via multiplicative decay.
    ///
    /// - Parameter issues: The active `HealthIssue` list.
    /// - Returns: A bounded integer score [0, 100].
    private func calculateScore(issues: [HealthIssue]) -> Int {
        /// Multiplicative decay rather than additive `100 − Σweight`. The old model
        /// saturated to 0 at ~5 criticals, so a bad machine and a catastrophic one
        /// both read "0" with no resolution. Decay degrades smoothly and asymptotes
        /// toward 0, staying meaningful at the bad end. Severity sets the per-issue
        /// factor (critical hits hardest).
        ///
        /// **Rationale:** Exponential decay algorithms natively preserve mathematical differentiation in the UI even when the environment is profoundly corrupted.
        let criticals = issues.filter { $0.severity == .critical }.count
        let warnings  = issues.filter { $0.severity == .warning }.count
        let infos     = issues.filter { $0.severity == .info }.count

        let factor = pow(0.7, Double(criticals))
                   * pow(0.9, Double(warnings))
                   * pow(0.98, Double(infos))
        return max(0, min(100, Int((100.0 * factor).rounded())))
    }
}
