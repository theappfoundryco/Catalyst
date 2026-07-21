import Foundation

/// A diagnostic tool that evaluates disk space usage from common developer caches.
///
/// This checker looks at directories like Xcode's DerivedData and the NPM cache, which can grow significantly over time.
struct DiskHygieneDoctor: Doctor {
    var category: HealthCategory { .disk }


    /// Scans developer cache directories to identify excessive disk usage.
    ///
    /// - Returns: An array of `HealthIssue` objects representing actionable cache folders to clean.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        
        // 1. Xcode DerivedData
        let derivedData = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        if let size = await getDirectorySize(derivedData.path), size.bytes > 5_000_000_000 { // 5GB
             issues.append(HealthIssue(
                category: .disk,
                title: "Large DerivedData (\(size.formatted))",
                description: "Xcode build cache is using a lot of space.",
                severity: .info,
                autoFixAvailable: true,
                fixID: .clearDerivedData
            ))
        }
        
        // 2. NPM Cache
        do {
            let npmCache = try await AsyncProcessRunner.shared.run(command: "npm config get cache")
            let path = npmCache.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
               if let size = await getDirectorySize(path), size.bytes > 2_000_000_000 { // 2GB
                     issues.append(HealthIssue(
                        category: .disk,
                        title: "Large NPM Cache (\(size.formatted))",
                        description: "NPM cache is quite large.",
                        severity: .info,
                        autoFixAvailable: true,
                        fixID: .clearNPMCache
                    ))
               }
            }
        } catch {}
        
        return issues
    }
    
    // Helper
    private func getDirectorySize(_ path: String) async -> (formatted: String, bytes: Int64)? {
        let command = "du -s -k '\(path)' 2>/dev/null | awk '{print $1}'" // kilobytes
        return await Task.detached {
            do {
                let res = try await AsyncProcessRunner.shared.run(command: command)
                if let kbStr = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines) as String?, let kb = Int64(kbStr) {
                    let bytes = kb * 1024
                    let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    return (formatted, bytes)
                }
            } catch {}
            return nil
        }.value
    }
    
    /// Attempts to free up disk space by cleaning identified cache directories.
    ///
    /// - Parameter issue: The disk hygiene issue specifying which cache to clear.
    /// - Returns: A boolean indicating whether the cleanup operation was successful.
    func fix(_ issue: HealthIssue) async -> Bool {
        if issue.fixID == .clearDerivedData {
             let home = FileManager.default.homeDirectoryForCurrentUser
             let derivedData = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
             do {
                 try FileManager.default.removeItem(at: derivedData)
                 return true
             } catch {
                 Logger.shared.log("❌ Failed to clear DerivedData: \(error.localizedDescription)")
                 return false
             }
        }
        if issue.fixID == .clearNPMCache {
            let res = try? await AsyncProcessRunner.shared.run(command: "npm cache clean --force")
            return res?.succeeded ?? false
        }
        return false
    }
}
