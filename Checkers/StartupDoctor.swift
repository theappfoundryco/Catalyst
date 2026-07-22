import Foundation

/// A diagnostic check identifying stale or broken background startup items.
///
/// Scans system launch agent and daemon paths to flag binaries that no longer exist but remain scheduled.
struct StartupDoctor: Doctor {
    var category: HealthCategory { .startup }


    /// Evaluates LaunchAgents and LaunchDaemons against actively executing services and physical locations.
    ///
    /// **Flow:**
    /// 1. Reads standard `/Library` and `~/Library` launch paths aggregating valid `.plist` entities.
    /// 2. Executes `launchctl list` validating executing background daemons matching identifiers.
    /// 3. Cross-references internal `<Program>` XML structures ensuring binaries resolve logically on disk.
    ///
    /// - Returns: An array of `HealthIssue` highlighting missing executables and active background services.
    func run() async -> [HealthIssue] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        
        let scanPaths = [
            home.appendingPathComponent("Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchDaemons"),
            URL(fileURLWithPath: "/Library/LaunchAgents")
        ]
        
        var allPlists: [URL] = []
        for dir in scanPaths {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            allPlists.append(contentsOf: files.filter { $0.pathExtension == "plist" })
        }
        
        let issues = await withTaskGroup(of: HealthIssue?.self) { group in
            for plist in allPlists {
                group.addTask {
                    let label = plist.deletingPathExtension().lastPathComponent
                    
                    let result = try? await AsyncProcessRunner.shared.run(command: "launchctl list | grep \(label)")
                    let isRunning = result?.succeeded ?? false
                    
                    var binaryPath: String? = nil
                    
                    if let progResult = try? await AsyncProcessRunner.shared.run(command: "/usr/bin/plutil -extract Program raw -o - '\(plist.path)'"), progResult.succeeded {
                        binaryPath = progResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    
                    if let bin = binaryPath, !bin.isEmpty {
                        if !FileManager.default.fileExists(atPath: bin) {
                            return HealthIssue(
                                category: .startup,
                                title: "Broken Startup Item: \(label)",
                                description: "The binary '\(bin)' is missing. This agent is a zombie.",
                                severity: .warning,
                                autoFixAvailable: true,
                                fixID: .brokenStartupItem
                            )
                        }
                    }
                    
                    if isRunning {
                        return HealthIssue(
                            category: .startup,
                            title: "Active Service: \(label)",
                            description: "Background service is running. Location: \(plist.path)",
                            severity: .info,
                            autoFixAvailable: true,
                            fixID: .activeStartupService
                        )
                    }
                    
                    return nil
                }
            }
            
            var results: [HealthIssue] = []
            for await result in group {
                if let issue = result {
                    results.append(issue)
                }
            }
            return results
        }
        
        return issues
    }
    
    /// Unloads active legacy services or deletes broken plist files natively.
    ///
    /// **Gotchas:**
    /// Unloading `/Library/LaunchDaemons` often requires `sudo`, which may fail silently if Catalyst lacks elevated scope. Plist deletion handles zombie elements definitively.
    ///
    /// - Parameter issue: The startup issue detailing the label or broken executable.
    /// - Returns: A boolean indicating execution success for removal or unloading.
    func fix(_ issue: HealthIssue) async -> Bool {
        let titleParts = issue.title.components(separatedBy: ": ")
        guard titleParts.count == 2 else { return false }
        let label = titleParts[1]
        
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let possiblePaths = [
             home.appendingPathComponent("Library/LaunchAgents/\(label).plist"),
             URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist"),
             URL(fileURLWithPath: "/Library/LaunchAgents/\(label).plist")
        ]
        
        guard let path = possiblePaths.first(where: { fm.fileExists(atPath: $0.path) }) else { return false }
        
        if issue.fixID == .brokenStartupItem {
            do {
                try fm.removeItem(at: path)
                return true
            } catch {
                return false
            }
        } else {
            let res = try? await AsyncProcessRunner.shared.run(command: "launchctl unload -w '\(path.path)'")
            return res?.succeeded ?? false
        }
    }
}
