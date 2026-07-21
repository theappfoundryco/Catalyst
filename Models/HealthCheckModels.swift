import Foundation

/// Defines standard threshold gradients used to represent system performance implications.
enum HealthSeverity: String, Codable, Sendable {
    /// Indicates an active failure requiring immediate intervention.
    case critical
    /// Indicates a notable operational risk that degrades execution pipelines.
    case warning
    /// Indicates a structural notification carrying no performance regressions.
    case info
    
    /// Translates severity classes into numeric weights utilized during systemic health aggregations.
    var scoreWeight: Int {
        switch self {
        case .critical: return 20
        case .warning: return 5
        case .info: return 1
        }
    }
}

/// Categorizes distinct hardware and software audit topologies.
enum HealthCategory: String, Codable, CaseIterable, Sendable {
    /// Relates to environment sourcing execution issues.
    case shell = "Shell Integrity"
    /// Relates to terminal path variable resolution bugs.
    case path = "Path Configuration"
    /// Relates to third-party execution layer prerequisites.
    case tools = "Developer Tools"
    /// Relates to operational bound limits surrounding file system structures.
    case permissions = "File Permissions"
    /// Relates to outbound socket connections.
    case network = "Network Config"
    /// Relates to isolated container daemon instances.
    case container = "Docker / Containers"
    /// Relates to physical storage constraints.
    case disk = "Disk Hygiene"
    /// Relates to encryption key configurations.
    case security = "Security / Identity"
    /// Relates to hardware logic translations extending to distinct binary models.
    case architecture = "Architecture / Silicon"
    /// Relates to the Java runtime daemon processes.
    case java = "Java Environment"
    /// Relates to system network isolation logic blocks.
    case firewall = "Firewall / Network"
    /// Relates to the macOS boot execution framework pipelines.
    case startup = "Startup Profiler"
    /// Relates to JavaScript execution dependency constraints.
    case node = "Node.js / NPM"
    /// Relates to active RAM and swap data structures.
    case memory = "Memory & Performance"
}

/// A stable identifier for an auto-fixable issue, used to route `fix(_:)` to the
/// owning doctor. Decoupled from the display `title` so rewording or localizing a
/// title can never break auto-fix routing.
enum HealthFix: String, Codable, Sendable {
    case shellConfigNotSourced
    case systemPythonDefault
    case missingXcodeTools
    case excessiveBackups
    case portInUse
    case pruneZombieContainers
    case pruneDanglingImages
    case clearDerivedData
    case clearNPMCache
    case fixSSHDirPermissions
    case fixSSHKeyPermissions
    case fixNPMOwnership
    case strictFirewallMode
    case stealthModeEnabled
    case brokenStartupItem
    case activeStartupService
}

/// A serialized representation reporting a specific error identified during diagnostic cycles.
struct HealthIssue: Identifiable, Codable, Sendable {
    /// A unique random identification token necessary for SwiftUI diffing arrays.
    var id = UUID()
    /// The diagnostic topology segment originating the failure condition.
    let category: HealthCategory
    /// A highly condensed explanation detailing the operational fault.
    let title: String
    /// An extended diagnostic block proposing context and reasoning.
    let description: String
    /// The determined urgency classifying impact weight.
    let severity: HealthSeverity
    /// A boolean delineating if a programmed software path exists to clear the warning via prompt.
    let autoFixAvailable: Bool
    /// Stable routing key for auto-fix; `nil` for non-fixable issues. Defaulted so
    /// existing initializers remain valid via the synthesized memberwise init.
    var fixID: HealthFix? = nil
}

/// The common contract every diagnostic checker conforms to. Holding all doctors
/// in one `[Doctor]` array lets `HealthCheckService` derive both the scan loop and
/// fix routing without hard-coding each module in several places.
protocol Doctor {
    /// The primary category this doctor reports under. Used to map availability
    /// (notInstalled) to a status row; issue aggregation is by each issue's own category.
    var category: HealthCategory { get }
    /// Runs the diagnostic and returns any issues found.
    func run() async -> [HealthIssue]
    /// Attempts to auto-fix an issue this doctor owns (matched by `issue.fixID`).
    /// Returns false for issues it doesn't own, so the service can try each doctor.
    func fix(_ issue: HealthIssue) async -> Bool
}

extension Doctor {
    /// Doctors with no auto-fix capability inherit this no-op.
    func fix(_ issue: HealthIssue) async -> Bool { false }
}

/// Refinement for doctors whose tool may be absent (Docker/Java/Node). When the
/// tool isn't installed the service reports `.notInstalled` instead of running.
protocol AvailabilityCheckable {
    func checkAvailability() async -> Bool
}

/// A serialized aggregate point modeling a systemic audit event inside local history bounds.
struct HealthSnapshot: Identifiable, Codable, Sendable {
    /// A unique random identification token necessary for SwiftUI interface layers.
    var id = UUID()
    /// The precise system timestamp capturing event completion coordinates.
    let date: Date
    /// A compiled analytic metric modeling exact hardware fitness at runtime execution.
    let score: Int
    /// An absolute count detailing aggregate warnings discovered.
    let issueCount: Int
    /// An absolute count detailing instances matching the critical designation pattern.
    let criticalCount: Int
}

/// Summarizes the execution status of an individual diagnostic module segment.
struct DoctorStatus: Identifiable, Codable, Sendable {
    /// Maps directly into the primary category enumeration to establish a stable structural identity reference.
    var id: String { category.rawValue }
    /// The broad topology bucket assigned to this analysis phase.
    let category: HealthCategory
    /// The resolved terminal logic state.
    let status: Status
    
    /// Expresses standard lifecycle completion markers mapped to discrete modules.
    enum Status: Codable, Equatable, Sendable {
        /// Verification logic executed entirely returning cleanly without incident.
        case passed
        /// Target requirements were not satisfied triggering a fault condition block yielding an isolated issue count.
        case failed(count: Int)
        /// Internal skip triggers blocked logic evaluation rendering diagnostics incomplete.
        case skipped
        /// Initial context parsing determined core requirements missing outright blocking further assertions.
        case notInstalled(String?)
        
        /// Resolves true exclusively when verifying successful completion states without fault instances.
        var isPassed: Bool {
            if case .passed = self { return true }
            return false
        }
    }
}

/// An aggregated diagnostic envelope consolidating multiple scanner instances.
struct ScanResult: Sendable {
    /// A collective map grouping all disparate failure structures natively generated during audit processing.
    let issues: [HealthIssue]
    /// A module array resolving granular terminal logic completion properties corresponding to scanning topologies.
    let doctorStatuses: [DoctorStatus]
}
