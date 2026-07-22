import Foundation

/// A tracked filesystem directory monitored for excessive cruft accumulation.
struct StorageCategory: Identifiable {
    let id = UUID()
    let name: String
    let bytes: Int64
    let colorHex: String
}

/// The aggregated footprint metrics across all monitored storage partitions.
struct StorageReport {
    let totalSize: Int64
    let usedSize: Int64
    let freeSize: Int64
    let categories: [StorageCategory]
    
    var percentUsed: Double {
        /// Guard against divide-by-zero when volume attributes were unavailable.
        ///
        /// **Gotchas:** `volumeTotalCapacity` returns `0` inside tightly sandboxed environments (like test harnesses), causing fatal math crashes if not guarded.
        guard totalSize > 0 else { return 0 }
        return Double(usedSize) / Double(totalSize)
    }
}

/// A diagnostic checker that analyzes disk consumption by categorizing development tool payloads.
///
/// Sweeps standard cache and derived data directories to produce an actionable storage report.
class StorageDoctor {
    
    /// Executes a concurrent scan of predetermined high-density developer payload directories.
    ///
    /// **Flow:**
    /// 1. Attempts extracting APFS optimized volume limits resolving correct available storage contexts.
    /// 2. Spawns concurrent `du -sk` execution evaluations assessing Homebrew, Docker, and caching directories (NPM/Pip/CocoaPods).
    /// 3. Aggregates values into categorized storage segments assigned to distinct UI elements.
    ///
    /// - Returns: A full `StorageReport` categorizing used space by toolchains like Xcode, Docker, and NPM.
    func scan() async -> StorageReport {
        let fileManager = FileManager.default
        
        var total: Int64 = 0
        var free: Int64 = 0

        /// Prefer the URL resource values: volumeAvailableCapacityForImportantUsage
        /// accounts for APFS purgeable space, unlike systemFreeSize which reports
        /// the raw volume free space and overstates what's actually reclaimable.
        ///
        /// **Rationale:** APFS dynamically allocates space for Time Machine local snapshots. `systemFreeSize` ignores these snapshots, yielding wildly inaccurate "free space" metrics.
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? homeURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) {
            if let totalCap = values.volumeTotalCapacity { total = Int64(totalCap) }
            if let importantFree = values.volumeAvailableCapacityForImportantUsage { free = importantFree }
        }

        /// Fallback to the file-system attributes if the resource keys were unavailable.
        ///
        /// **Gotchas:** `attributesOfFileSystem` reads static inode structures which lack APFS dynamic awareness; use exclusively as a last resort.
        if total == 0, let attrs = try? fileManager.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            total = (attrs[.systemSize] as? Int64) ?? 0
            free = (attrs[.systemFreeSize] as? Int64) ?? 0
        }

        let used = max(0, total - free)
        
        async let dockerSize = getFolderSize(at: userHome + "/Library/Containers/com.docker.docker")
        async let xcodeDataSize = getFolderSize(at: userHome + "/Library/Developer/Xcode/DerivedData")
        async let xcodeArchiveSize = getFolderSize(at: userHome + "/Library/Developer/Xcode/Archives")
        async let brewSize = getFolderSize(at: BrewPathManager.shared.homebrewPrefix)
        async let npmCacheSize = getFolderSize(at: userHome + "/.npm")
        async let cocoaPodsSize = getFolderSize(at: userHome + "/Library/Caches/CocoaPods")
        async let pipCacheSize = getFolderSize(at: userHome + "/Library/Caches/pip")
        
        let categories = [
            StorageCategory(name: "Docker", bytes: await dockerSize, colorHex: "#0db7ed"),
            StorageCategory(name: "Xcode Data", bytes: (await xcodeDataSize) + (await xcodeArchiveSize), colorHex: "#157FFB"),
            StorageCategory(name: "Homebrew", bytes: await brewSize, colorHex: "#F28D00"),
            StorageCategory(name: "NPM/Pip Caches", bytes: (await npmCacheSize) + (await pipCacheSize) + (await cocoaPodsSize), colorHex: "#CC3534"),
        ]
        
        return StorageReport(
            totalSize: total,
            usedSize: used,
            freeSize: free,
            categories: categories.sorted(by: { $0.bytes > $1.bytes })
        )
    }
    
    private var userHome: String {
        return NSHomeDirectory()
    }
    
    /// Recursively calculates the byte size of a target filesystem path via `du`.
    private func getFolderSize(at path: String) async -> Int64 {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        
        do {
            let result = try await AsyncProcessRunner.shared.run(command: "du -sk \(InputSanitizer.singleQuote(path)) | cut -f1")
            if result.succeeded, let kbStr = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).last {
                if let kb = Int64(kbStr) {
                    return kb * 1024
                }
            }
        } catch {
        }
        return 0
    }
}
