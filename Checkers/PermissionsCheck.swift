import Foundation

/// A diagnostic checker validating file and directory read and write permissions.
///
/// Ensures Catalyst can operate correctly and monitors application support boundaries for clutter or denial.
struct PermissionsCheck: Doctor {
    var category: HealthCategory { .permissions }


    /// Evaluates application support paths and excessive historical backups.
    ///
    /// **Flow:**
    /// 1. Fetches write flags for `~/Library/Application Support/com.shivanggulati.catalyst`.
    /// 2. Iterates explicit `.zshrc.catalyst.backup` footprints stored directly in `$HOME`.
    ///
    /// - Returns: An array of `HealthIssue` detailing permission failures or redundant clutter.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        
        do {
            let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let catalystDir = appSupport.appendingPathComponent("com.shivanggulati.catalyst")
            
            if !fm.isWritableFile(atPath: catalystDir.path) && fm.fileExists(atPath: catalystDir.path) {
                 issues.append(HealthIssue(
                    category: .permissions,
                    title: "App Support Read-Only",
                    description: "Catalyst cannot write to its config directory (\(catalystDir.path)).",
                    severity: .critical,
                    autoFixAvailable: false
                ))
            }
        } catch {
             issues.append(HealthIssue(
                category: .permissions,
                title: "App Support Inaccessible",
                description: "Cannot access Application Support directory: \(error.localizedDescription)",
                severity: .critical,
                autoFixAvailable: false
            ))
        }
        
        do {
            let files = try fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
            let backups = files.filter { $0.lastPathComponent.contains(".zshrc.catalyst.backup") }
            
            if backups.count > 5 {
                issues.append(HealthIssue(
                    category: .permissions,
                    title: "Excessive Backups",
                    description: "Found \(backups.count) config backup files in your home directory.",
                    severity: .info,
                    autoFixAvailable: true,
                    fixID: .excessiveBackups
                ))
            }
        } catch {}
        
        return issues
    }
    
    /// Clears permission constraints or cleans excessive backup items.
    ///
    /// **Gotchas:**
    /// Evaluates file creation dates across raw URLs, keeping the 3 most recent configurations intact.
    ///
    /// - Parameter issue: The permission finding isolated on execution.
    /// - Returns: A boolean describing the final cleanup execution status.
    func fix(_ issue: HealthIssue) async -> Bool {
        if issue.fixID == .excessiveBackups {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            do {
                let files = try fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
                let backups = files.filter { $0.lastPathComponent.contains(".zshrc.catalyst.backup") }
                
                let datedBackups = backups.map { url -> (URL, Date) in
                    let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    return (url, date)
                }
                let sorted = datedBackups.sorted { $0.1 > $1.1 }
                
                for (file, _) in sorted.dropFirst(3) {
                    try fm.removeItem(at: file)
                }
                return true
            } catch {
                return false
            }
        }
        return false
    }
}
