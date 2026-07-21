import Foundation

/// An operational service dictating the retrieval and interpretation of SMART drive health constraints.
///
/// Orchestrates the prerequisite toolchain dependencies and parses `smartctl` console streams.
final class SSDHealthService: Sendable {
    
    static let shared = SSDHealthService()
    
    private init() {}
    
    /// Establishes whether the foundational `smartmontools` Homebrew binary is present.
    ///
    /// - Returns: A boolean confirming target availability on the user `$PATH`.
    func isSmartctlInstalled() async -> Bool {
        do {
            let result = try await AsyncProcessRunner.shared.runWithBrewPath(
                command: "which smartctl"
            )
            return result.succeeded && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }
    
    /// Installs the `smartmontools` dependency required to interface with primary SSD hardware layers.
    ///
    /// - Parameter onOutput: A closure callback for terminal output parsing.
    /// - Returns: A boolean indicating explicit command success or failure codes.
    func installSmartmontools(
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        let brewPath = InputSanitizer.singleQuote(BrewPathManager.shared.brewPath)
        let command = "\(brewPath) install smartmontools"
        
        do {
            let exitCode = try await AsyncProcessRunner.shared.runWithStreaming(
                command: command,
                onOutput: onOutput
            )
            return exitCode == 0
        } catch {
            Logger.shared.log("❌ Failed to install smartmontools: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Queries the basic logical nodes to infer the current hardware boot disk.
    ///
    /// - Returns: The string format device descriptor.
    func detectBootDisk() async -> String? {
        await Task.detached {
            // Resolve the *physical* whole disk backing "/". On APFS, "/" is a
            // synthesized volume (e.g. disk3s1s1) whose container's physical store
            // is the real NVMe device (e.g. disk0) — that's what smartctl needs.
            // Parse `diskutil info -plist` rather than regex-stripping the node.
            do {
                let result = try await AsyncProcessRunner.shared.run(command: "diskutil info -plist /")
                if let data = result.stdout.data(using: .utf8),
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {

                    // Prefer the APFS physical store (the real disk), e.g. "disk0s2".
                    if let stores = plist["APFSPhysicalStores"] as? [[String: Any]],
                       let dev = stores.first?["APFSPhysicalStore"] as? String,
                       let whole = Self.wholeDisk(from: dev) {
                        return "/dev/\(whole)"
                    }
                    // Otherwise the parent whole disk of the volume.
                    if let parent = plist["ParentWholeDisk"] as? String,
                       let whole = Self.wholeDisk(from: parent) {
                        return "/dev/\(whole)"
                    }
                    if let node = plist["DeviceNode"] as? String,
                       let whole = Self.wholeDisk(from: node) {
                        return "/dev/\(whole)"
                    }
                }
                Logger.shared.log("⚠️ Could not resolve boot disk from diskutil plist")
                return nil
            } catch {
                Logger.shared.log("❌ Failed to detect boot disk: \(error.localizedDescription)")
                return nil
            }
        }.value
    }

    /// Reduces a device identifier/node to its whole-disk id, anchored on the
    /// `diskN` prefix (e.g. "/dev/disk0s2" or "disk3s1s1" → "disk0"/"disk3").
    static func wholeDisk(from identifier: String) -> String? {
        let name = (identifier as NSString).lastPathComponent
        guard let match = name.range(of: "^disk[0-9]+", options: .regularExpression) else { return nil }
        return String(name[match])
    }
    
    /// Commences an authenticated disk operation scanning hardware endpoints.
    ///
    /// - Parameters:
    ///   - disk: The targeted system partition descriptor string.
    ///   - privileges: The execution wrapper required to prompt system access limits.
    /// - Returns: A structured `SSDHealthReport` aggregating returned hardware data.
    func scan(disk: String, privileges: PrivilegesService) async throws -> SSDHealthReport? {
        try await Task.detached {
            let sanitizedDisk = InputSanitizer.singleQuote(disk)
            
            let whichResult = try await AsyncProcessRunner.shared.runWithBrewPath(
                command: "which smartctl"
            )
            let smartctlPath = whichResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !smartctlPath.isEmpty else {
                Logger.shared.log("❌ smartctl not found in PATH")
                return nil
            }
            
            // Capture smartctl's exit code explicitly. The osascript/`do shell
            // script` wrapper swallows the child's status, and the previous
            // `|| true` forced it to 0 — masking real failures (permission
            // denied, device busy, unsupported bus). Echo the status on a
            // trailing marker line and branch on it. smartctl uses a bit-coded
            // exit status: bits 0–1 (mask 0x03) mean "command line error" or
            // "device open failed" — i.e. we never got valid data. Higher bits
            // are SMART health conditions where the data is still valid.
            let exitMarker = "__CATALYST_SMARTCTL_EXIT__"
            let command = "\(InputSanitizer.singleQuote(smartctlPath)) -a \(sanitizedDisk); printf '\\n\(exitMarker)%d' \"$?\""

            let (_, rawOutput) = try await privileges.runWithPrivileges(command: command)

            // Split the exit marker back off the output.
            var output = rawOutput
            var smartctlExit: Int32 = 0
            if let range = rawOutput.range(of: exitMarker) {
                let codeString = rawOutput[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                smartctlExit = Int32(codeString) ?? 0
                output = String(rawOutput[..<range.lowerBound])
            }

            guard !output.isEmpty else {
                Logger.shared.log("❌ smartctl returned empty output")
                return nil
            }

            if smartctlExit & 0x03 != 0 {
                Logger.shared.log("❌ smartctl could not read the drive (exit \(smartctlExit)). Permission denied, device busy, or unsupported.")
                return nil
            }

            guard output.contains("SMART overall-health") || output.contains("START OF SMART DATA SECTION") else {
                Logger.shared.log("❌ Output does not look like valid SMART data. smartctl might be missing or failed.")
                return nil
            }

            // The parser only understands NVMe SMART logs. SATA/ATA and
            // USB-bridge drives produce the ATA attribute table instead, which
            // every NVMe key misses — yielding an all-zeros report shown as
            // real data. Reject non-NVMe drives explicitly.
            let isNVMe = output.contains("NVMe Log")
                || output.contains("NVMe Version")
                || output.contains("Number of Namespaces")
            guard isNVMe else {
                Logger.shared.log("❌ This drive is not NVMe (SATA/ATA or USB-bridge). Catalyst's SSD report currently supports NVMe drives only.")
                return nil
            }

            return self.parseSmartctlOutput(output)
        }.value
    }
    
    /// Normalizes raw terminal output derived from `smartctl` into static, consumable structures.
    ///
    /// - Parameter output: The raw buffer stream output from the dependency process.
    /// - Returns: A synthesized view of internal component performance benchmarks.
    func parseSmartctlOutput(_ output: String) -> SSDHealthReport? {
        let lines = output.components(separatedBy: .newlines)
        
        let overallHealth = extractValue(from: lines, key: "SMART overall-health self-assessment test result") ?? "UNKNOWN"
        
        let modelNumber = extractValue(from: lines, key: "Model Number") ?? "Unknown"
        let serialNumber = extractValue(from: lines, key: "Serial Number") ?? "Unknown"
        let firmwareVersion = extractValue(from: lines, key: "Firmware Version") ?? "Unknown"
        let nvmeVersion = extractValue(from: lines, key: "NVMe Version") ?? "Unknown"
        let numberOfNamespaces = Int(extractValue(from: lines, key: "Number of Namespaces") ?? "0") ?? 0
        let maxDataTransferSize = extractValue(from: lines, key: "Maximum Data Transfer Size") ?? "Unknown"
        let pciVendorID = extractValue(from: lines, key: "PCI Vendor/Subsystem ID") ?? "Unknown"
        
        let driveInfo = DriveInfo(
            modelNumber: modelNumber,
            serialNumber: serialNumber,
            firmwareVersion: firmwareVersion,
            nvmeVersion: nvmeVersion,
            numberOfNamespaces: numberOfNamespaces,
            maxDataTransferSize: maxDataTransferSize,
            pciVendorID: pciVendorID
        )
        
        let temperatureCelsius = extractIntFromLine(lines, key: "Temperature")
        let availableSpare = extractPercentage(from: lines, key: "Available Spare:")
        let availableSpareThreshold = extractPercentage(from: lines, key: "Available Spare Threshold")
        let percentageUsed = extractPercentage(from: lines, key: "Percentage Used")
        let powerCycles = extractIntWithCommas(from: lines, key: "Power Cycles")
        let powerOnHours = extractIntWithCommas(from: lines, key: "Power On Hours")
        let unsafeShutdowns = extractIntWithCommas(from: lines, key: "Unsafe Shutdowns")
        let controllerBusyTime = extractIntWithCommas(from: lines, key: "Controller Busy Time")
        
        let healthMetrics = HealthMetrics(
            temperatureCelsius: temperatureCelsius,
            availableSpare: availableSpare,
            availableSpareThreshold: availableSpareThreshold,
            percentageUsed: percentageUsed,
            powerCycles: powerCycles,
            powerOnHours: powerOnHours,
            unsafeShutdowns: unsafeShutdowns,
            controllerBusyTime: controllerBusyTime
        )
        
        let dataUnitsRead = extractDataUnits(from: lines, key: "Data Units Read")
        let dataUnitsWritten = extractDataUnits(from: lines, key: "Data Units Written")
        let dataReadFormatted = extractFormattedData(from: lines, key: "Data Units Read")
        let dataWrittenFormatted = extractFormattedData(from: lines, key: "Data Units Written")
        let hostReadCommands = extractInt64WithCommas(from: lines, key: "Host Read Commands")
        let hostWriteCommands = extractInt64WithCommas(from: lines, key: "Host Write Commands")
        
        let dataTransfer = DataTransfer(
            dataUnitsRead: dataUnitsRead,
            dataUnitsWritten: dataUnitsWritten,
            dataReadFormatted: dataReadFormatted,
            dataWrittenFormatted: dataWrittenFormatted,
            hostReadCommands: hostReadCommands,
            hostWriteCommands: hostWriteCommands
        )
        
        let criticalWarning = extractHexValue(from: lines, key: "Critical Warning")
        let mediaErrors = extractIntWithCommas(from: lines, key: "Media and Data Integrity Errors")
        let errorLogEntries = extractIntWithCommas(from: lines, key: "Error Information Log Entries")
        
        let errorInfo = ErrorInfo(
            criticalWarning: criticalWarning,
            mediaErrors: mediaErrors,
            errorLogEntries: errorLogEntries
        )

        let storageInfo = buildStorageInfo(from: lines)

        return SSDHealthReport(
            scanDate: Date(),
            overallHealth: overallHealth,
            driveInfo: driveInfo,
            healthMetrics: healthMetrics,
            dataTransfer: dataTransfer,
            errorInfo: errorInfo,
            storageInfo: storageInfo
        )
    }

    /// Assembles the capacity snapshot: boot-volume usage from the filesystem and
    /// the drive's advertised raw NVM capacity parsed from the smartctl identify
    /// block (the `[…]` human-readable form, e.g. "500 GB").
    private func buildStorageInfo(from lines: [String]) -> StorageInfo {
        // Volume capacity. Prefer the APFS-purgeable-aware resource keys (same
        // approach as StorageDoctor) so "free" reflects what's actually usable.
        var total: Int64 = 0
        var free: Int64 = 0
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? homeURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) {
            if let totalCap = values.volumeTotalCapacity { total = Int64(totalCap) }
            if let importantFree = values.volumeAvailableCapacityForImportantUsage { free = importantFree }
        }
        if total == 0, let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            total = (attrs[.systemSize] as? Int64) ?? 0
            free = (attrs[.systemFreeSize] as? Int64) ?? 0
        }

        // Raw NVM capacity. smartctl prints e.g.
        //   Total NVM Capacity:  500,107,862,016 [500 GB]
        //   Namespace 1 Size/Capacity: 500,107,862,016 [500 GB]
        // Pull the bracketed human-readable form; fall back to "Unknown".
        let rawCapacity = extractValue(from: lines, key: "Total NVM Capacity")
            ?? extractValue(from: lines, key: "Namespace 1 Size/Capacity")
        var nvmCapacity = "Unknown"
        if let rawCapacity,
           let start = rawCapacity.firstIndex(of: "["),
           let end = rawCapacity.firstIndex(of: "]") {
            nvmCapacity = String(rawCapacity[rawCapacity.index(after: start)..<end])
        }

        return StorageInfo(totalBytes: total, freeBytes: free, nvmCapacityFormatted: nvmCapacity)
    }
    
    private var cacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let catalystDir = appSupport.appendingPathComponent("Catalyst")
        try? FileManager.default.createDirectory(at: catalystDir, withIntermediateDirectories: true)
        return catalystDir.appendingPathComponent("ssd_health_cache.json")
    }
    
    /// Archives standard testing snapshots persistently onto local application storage mediums.
    ///
    /// - Parameter report: The resulting diagnostic output requiring preservation.
    func saveReport(_ report: SSDHealthReport) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            try data.write(to: cacheURL)
            Logger.shared.log("💾 Saved SSD health report to cache")
        } catch {
            Logger.shared.log("⚠️ Failed to cache SSD report: \(error.localizedDescription)")
        }
    }
    
    /// Materializes serialized state configurations from existing drive caches.
    ///
    /// - Returns: Reconstructed structured definitions mirroring previously extracted data points.
    func loadCachedReport() -> SSDHealthReport? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }
        
        do {
            let data = try Data(contentsOf: cacheURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SSDHealthReport.self, from: data)
        } catch {
            Logger.shared.log("⚠️ Failed to load cached SSD report: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Returns the value for a `Field Name: value` line, matching the field name
    /// exactly (left of the first colon) rather than by substring. Substring
    /// matching let short keys collide with longer labels (e.g. "Temperature"
    /// matching "Warning Comp. Temperature" or "Temperature Sensor 1"). Callers
    /// may pass the key with or without a trailing colon.
    private func extractValue(from lines: [String], key: String) -> String? {
        let targetField = (key.hasSuffix(":") ? String(key.dropLast()) : key)
            .trimmingCharacters(in: .whitespaces)
        for line in lines {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let fieldName = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
            if fieldName == targetField {
                return line[line.index(after: colonIndex)...]
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
    
    private func extractPercentage(from lines: [String], key: String) -> Int {
        guard let value = extractValue(from: lines, key: key) else { return 0 }
        let digits = value.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
        return Int(digits) ?? 0
    }
    
    private func extractIntFromLine(_ lines: [String], key: String) -> Int {
        guard let value = extractValue(from: lines, key: key) else { return 0 }
        let digits = value.components(separatedBy: .whitespaces).first ?? "0"
        return Int(digits) ?? 0
    }
    
    private func extractIntWithCommas(from lines: [String], key: String) -> Int {
        guard let value = extractValue(from: lines, key: key) else { return 0 }
        let cleaned = value.replacingOccurrences(of: ",", with: "")
            .components(separatedBy: .whitespaces).first ?? "0"
        return Int(cleaned) ?? 0
    }
    
    private func extractInt64WithCommas(from lines: [String], key: String) -> Int64 {
        guard let value = extractValue(from: lines, key: key) else { return 0 }
        let cleaned = value.replacingOccurrences(of: ",", with: "")
            .components(separatedBy: .whitespaces).first ?? "0"
        return Int64(cleaned) ?? 0
    }
    
    private func extractHexValue(from lines: [String], key: String) -> Int {
        guard let value = extractValue(from: lines, key: key) else { return 0 }
        let hex = value.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("0x") {
            return Int(hex.dropFirst(2), radix: 16) ?? 0
        }
        return Int(hex) ?? 0
    }
    
    private func extractDataUnits(from lines: [String], key: String) -> Int64 {
        guard let value = extractValue(from: lines, key: key) else { return 0 }
        let numberPart = value.components(separatedBy: "[").first ?? value
        let cleaned = numberPart.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Int64(cleaned) ?? 0
    }
    
    private func extractFormattedData(from lines: [String], key: String) -> String {
        guard let value = extractValue(from: lines, key: key) else { return "N/A" }
        if let start = value.firstIndex(of: "["),
           let end = value.firstIndex(of: "]") {
            let content = value[value.index(after: start)..<end]
            return String(content)
        }
        return "N/A"
    }
}
