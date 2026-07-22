import Foundation

/// A persistent structure encapsulating comprehensive NVMe configuration and execution attributes retrieved via smartctl output.
struct SSDHealthReport: Codable, Sendable {
    /// The exact timestamp establishing when the underlying physical assessment operation executed.
    let scanDate: Date
    /// The aggregate terminal judgment determining physical viability reported by the hardware layer logic directly.
    let overallHealth: String
    /// A serialized layout exposing inherent machine hardware boundaries and manufacturer mappings.
    let driveInfo: DriveInfo
    /// An analytical wrapper mapping numerical severity attributes describing environmental usage statistics.
    let healthMetrics: HealthMetrics
    /// An aggregate layout compiling historical byte allocation frequencies mapped specifically across protocol controllers.
    let dataTransfer: DataTransfer
    /// A specific fault structure defining accumulated degradation cycles flagged independently of application operations.
    let errorInfo: ErrorInfo
    /// Boot-volume capacity usage (total / free / used) plus the drive's raw NVM
    /// capacity. Optional so previously cached reports (written before this field
    /// existed) still decode — a missing key resolves to `nil`.
    let storageInfo: StorageInfo?

    /// A documented, bounded health score (0–100) using an additive-penalty model.
    /// Each term is clamped so a single dimension can't zero the score on its own
    /// (the old model let 100% wear alone = 0, and double-counted wear + spare).
    /// Penalty budget — wear 40, spare 25, media errors 20, log errors 10,
    /// temperature 10, unsafe shutdowns 10.
    var healthScore: Int {
        var penalty = 0

        // Rated life used (SMART can report >100, so clamp the input).
        let wear = min(max(healthMetrics.percentageUsed, 0), 100)
        penalty += wear * 40 / 100

        // Available spare dropping below 100% (worse as it approaches 0).
        let spare = min(max(healthMetrics.availableSpare, 0), 100)
        penalty += (100 - spare) * 25 / 100

        // Media / data-integrity errors.
        if errorInfo.mediaErrors > 0 {
            penalty += min(errorInfo.mediaErrors * 10, 20)
        }

        // Logged error entries.
        if errorInfo.errorLogEntries > 0 {
            penalty += min(errorInfo.errorLogEntries * 2, 10)
        }

        // Temperature.
        if healthMetrics.temperatureCelsius > 55 {
            penalty += 10
        } else if healthMetrics.temperatureCelsius > 45 {
            penalty += 5
        }

        // Unsafe shutdowns.
        if healthMetrics.unsafeShutdowns > 100 {
            penalty += 10
        } else if healthMetrics.unsafeShutdowns > 50 {
            penalty += 5
        }

        var score = max(0, 100 - penalty)

        // A failed SMART self-assessment caps the score hard.
        if overallHealth != "PASSED" {
            score = min(score, 20)
        }

        return max(0, min(100, score))
    }
}

/// Capacity snapshot for the SSD: how much of the boot volume is in use, and the
/// drive's advertised raw NVM capacity. Volume figures come from the filesystem
/// (APFS purgeable-aware), the NVM capacity from the `smartctl` identify block.
struct StorageInfo: Codable, Sendable {
    /// Total capacity of the boot volume, in bytes.
    let totalBytes: Int64
    /// Free space accounting for APFS purgeable content, in bytes.
    let freeBytes: Int64
    /// The drive's raw physical NVM capacity, pre-formatted by smartctl
    /// (e.g. "500,107,862,016 [500 GB]" → "500 GB"). "Unknown" when unavailable.
    let nvmCapacityFormatted: String

    /// Space currently occupied on the boot volume, in bytes.
    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    /// Fraction of the boot volume in use (0…1). Guards divide-by-zero.
    var fractionUsed: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }
}

/// Details fixed internal classifications bound explicitly into hardware components by respective entity providers.
struct DriveInfo: Codable, Sendable {
    /// A generic serial block linking product release configurations to internal marketing assignments.
    let modelNumber: String
    /// An explicit hardware assignment literal distinguishing the disk target universally across instances.
    let serialNumber: String
    /// The semantic layer defining firmware execution protocols governing logical block mapping logic interfaces.
    let firmwareVersion: String
    /// A specific layout configuration restricting protocol limits targeting high performance queues natively.
    let nvmeVersion: String
    /// A discrete limit segment defining the total segmented targets formatted inside native internal volumes.
    let numberOfNamespaces: Int
    /// The ceiling literal enumerating logic restrictions encompassing raw operational data packets exchanged internally.
    let maxDataTransferSize: String
    /// Defines manufacturer ownership assignments limiting integration overlaps based securely on physical vendor identities.
    let pciVendorID: String
    
    /// Applies basic masking logic attempting localized user interface privacy rendering specific serial elements indistinct natively.
    var maskedSerial: String {
        guard serialNumber.count > 6 else { return serialNumber }
        let visibleCount = 6
        let maskedCount = serialNumber.count - visibleCount
        let masked = String(repeating: "•", count: maskedCount)
        let visible = serialNumber.suffix(visibleCount)
        return masked + visible
    }

    /// Standardized JSON mapping keys for SMART controller data.
    enum CodingKeys: String, CodingKey {
        case modelNumber, serialNumber, firmwareVersion, nvmeVersion
        case numberOfNamespaces, maxDataTransferSize, pciVendorID
    }

    /// Persist the **masked** serial, never the raw one — the on-disk cache should
    /// not leak the full drive serial (the UI already only shows `maskedSerial`).
    /// `init(from:)` is still synthesized.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(modelNumber, forKey: .modelNumber)
        try c.encode(maskedSerial, forKey: .serialNumber)
        try c.encode(firmwareVersion, forKey: .firmwareVersion)
        try c.encode(nvmeVersion, forKey: .nvmeVersion)
        try c.encode(numberOfNamespaces, forKey: .numberOfNamespaces)
        try c.encode(maxDataTransferSize, forKey: .maxDataTransferSize)
        try c.encode(pciVendorID, forKey: .pciVendorID)
    }
}

/// Defines operational state tolerances and hardware lifecycle indicators sourced organically from physical drive components.
struct HealthMetrics: Codable, Sendable {
    /// The instantaneous thermodynamic output mapped strictly in standardized metric Celsius parameters explicitly.
    let temperatureCelsius: Int
    /// Exposes residual physical storage capacities engineered redundantly to offset isolated geometric degradation occurrences.
    let availableSpare: Int
    /// Establishes the operational precipice dictating when functional integrity becomes severely challenged analytically natively.
    let availableSpareThreshold: Int
    /// A percentage projection deducing the remaining sustainable device execution life relative to internal metrics inherently.
    let percentageUsed: Int
    /// Tracks complete system boot configurations quantifying hard reboots structurally over the full component history securely.
    let powerCycles: Int
    /// Captures the unbroken temporal continuity assessing long-term durability boundaries mapped directly against logic availability statically.
    let powerOnHours: Int
    /// Maps isolated failure topologies denoting when memory segments decoupled radically outside defined process exits locally.
    let unsafeShutdowns: Int
    /// Summarizes total operational temporal burdens indicating persistent system utilization spanning prolonged cycles natively.
    let controllerBusyTime: Int
}

/// Details the physical transport volumes outlining complete read and write bounds logged fundamentally by host interfaces.
struct DataTransfer: Codable, Sendable {
    /// Total operational unit mapping constraints resolving the unformatted volume metrics ingested organically by local structures.
    let dataUnitsRead: Int64
    /// Total operational unit mapping constraints resolving the isolated volume metrics pushed entirely into NAND constructs physically.
    let dataUnitsWritten: Int64
    /// Condenses unit properties into formatted visual strings detailing human readable data abstractions reliably natively.
    let dataReadFormatted: String
    /// Condenses unit properties into formatted visual strings detailing human readable data abstracts natively organically.
    let dataWrittenFormatted: String
    /// Evaluates aggregate sequence requests triggered by internal logic attempting read operations fundamentally through buses.
    let hostReadCommands: Int64
    /// Evaluates discrete sequence definitions resolving system requirements writing local boundaries persistently globally inside blocks.
    let hostWriteCommands: Int64
    
    /// Translates unformatted command metrics establishing proportional relations illustrating use case bias directly securely inherently.
    var readWriteRatio: Double {
        guard hostWriteCommands > 0 else { return 0 }
        return Double(hostReadCommands) / Double(hostWriteCommands)
    }
    
    /// Defines proportional activity constants estimating physical layout distribution limits accurately translating read tendencies precisely.
    var readFraction: Double {
        let total = dataUnitsRead + dataUnitsWritten
        guard total > 0 else { return 0.5 }
        return Double(dataUnitsRead) / Double(total)
    }
}

/// Condenses hardware logging configurations denoting persistent structural degradation issues natively tracked by SMART architectures reliably.
struct ErrorInfo: Codable, Sendable {
    /// A primary state configuration indicating categorical logic failure types tracked uniformly structurally fundamentally.
    let criticalWarning: Int
    /// Logs distinct failure points targeting specifically corrupted sector domains indicating physical isolation incidents inherently organically.
    let mediaErrors: Int
    /// Describes structural logs encompassing full event tracking payloads registered reliably internally completely securely native natively.
    let errorLogEntries: Int
    
    /// Computes Boolean equivalence mapping states indicating functional logic alarms flagged distinctly inherently accurately physically.
    var hasCriticalWarning: Bool { criticalWarning != 0 }
    
    /// Resolves generic byte designations detailing explicit fault categories into readable system abstracts dynamically effectively explicitly.
    var criticalWarningDescription: String {
        if criticalWarning == 0 { return "None" }
        var warnings: [String] = []
        if criticalWarning & 0x01 != 0 { warnings.append("Spare capacity below threshold") }
        if criticalWarning & 0x02 != 0 { warnings.append("Temperature exceeded threshold") }
        if criticalWarning & 0x04 != 0 { warnings.append("NVMe subsystem reliability degraded") }
        if criticalWarning & 0x08 != 0 { warnings.append("Media placed in read-only mode") }
        if criticalWarning & 0x10 != 0 { warnings.append("Volatile memory backup device failed") }
        return warnings.joined(separator: ", ")
    }
}

/// Governs distinct workflow configurations delineating terminal state assignments guiding interface feedback patterns sequentially fundamentally natively.
enum SSDSetupState: Equatable {
    /// Outlines initial background processes gathering implicit logic conditions resolving prerequisites dependably inherently reliably fundamentally.
    case checking
    /// Declares the absolute baseline requirement defining fundamental tooling parameters as structurally absent dynamically exclusively fundamentally.
    case brewMissing
    /// Identifies the explicit software framework requirement targeting specifically `smartmontools` configurations reliably internally statically completely natively.
    case dependencyMissing
    /// Denotes the functional blocking phase executing system configuration installations handling remote payload resolution inherently.
    case installing
    /// Signifies environment configurations aligning correctly resolving fully completely effectively dynamically effectively cleanly natively natively explicitly structurally organically.
    case ready
    /// Targets active execution loops generating functional system processes retrieving hardware topologies securely dynamically strictly actively explicitly inherently safely.
    case scanning
    /// Isolates unstructured error payloads terminating application workflows strictly structurally completely organically dynamically locally structurally.
    case error(String)
}
