import Foundation

/// A diagnostic check measuring the accuracy and safety of configured shell execution paths.
///
/// Ensures fundamental command line tools and runtimes prioritize appropriate package locations.
struct PathSanityCheck: Doctor {
    var category: HealthCategory { .path }
    private let logger = Logger.shared
    
    /// Scans the terminal path to detect Homebrew visibility and overlapping system Python boundaries.
    ///
    /// - Returns: An array of `HealthIssue` containing path irregularities or restricted Python use cases.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        
        if BrewPathManager.shared.isInstalled {
             do {
                let result = try await AsyncProcessRunner.shared.run(command: "which brew", useLoginShell: true)
                if !result.succeeded {
                     issues.append(HealthIssue(
                        category: .path,
                        title: "Homebrew Not in Path",
                        description: "Homebrew is installed at \(BrewPathManager.shared.brewPath) but 'brew' command is not found in your shell environment.",
                        severity: .warning,
                        autoFixAvailable: false
                    ))
                }
            } catch {
            }
        }
        
        do {
            let pythonCheck = try await AsyncProcessRunner.shared.run(command: "python3 -c \"import sys; print(sys.executable)\"", useLoginShell: true)
            
            if pythonCheck.succeeded {
                let path = pythonCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if path.hasPrefix("/usr/bin/python") || path.hasPrefix("/Library/Developer/") {
                     issues.append(HealthIssue(
                        category: .path,
                        title: "System Python is Default",
                        description: "Your shell is using the macOS system Python (\(path)). Installing packages here is restricted and can break system tools.",
                        severity: .warning,
                        autoFixAvailable: true,
                        fixID: .systemPythonDefault
                    ))
                }
            } else {
            }
        } catch {
        }
        
        return issues
    }
    
    /// Configures missing path structures within the shell profile to resolve detected alignment issues.
    ///
    /// - Parameter issue: The specific path conflict requiring resolution.
    /// - Returns: A boolean representing the successful application of the shell config updates.
    func fix(_ issue: HealthIssue) async -> Bool {
        if issue.fixID == .systemPythonDefault {
             let logger = Logger.shared
             let brewPrefix = BrewPathManager.shared.homebrewPrefix
             let brewBinPath = "\(brewPrefix)/bin"
             let brewExecutable = BrewPathManager.shared.brewPath
             let pythonPath = "\(brewBinPath)/python3"
             
             logger.log("🔧 Fixing System Python issue...")
             
             if !FileManager.default.fileExists(atPath: pythonPath) {
                 logger.log("🔍 Homebrew Python binary missing at \(pythonPath). Attempting to install/link...")
                 
                 let install = try? await AsyncProcessRunner.shared.run(command: "\(brewExecutable) install python")
                 if install?.succeeded == false {
                     logger.log("⚠️ Install failed: \(install?.stderr ?? ""). Trying link...")
                 }
                 
                 let link = try? await AsyncProcessRunner.shared.run(command: "\(brewExecutable) unlink python && \(brewExecutable) link --overwrite python")
                 if link?.succeeded == false {
                     logger.log("❌ Failed to link python: \(link?.stderr ?? "Unknown error")")
                 }
             }
             
             do {
                 _ = ShellConfigManager.shared.ensureCatalystSourced()
                 
                 let exportCommand = "export PATH=\"\(brewBinPath):$PATH\""
                 
                 let existingConfig = ShellConfigManager.shared.readCatalystConfig() ?? ""
                 
                 if !existingConfig.contains(exportCommand) {
                     try ShellConfigManager.shared.appendToCatalystConfig("\n# Fix System Python: Prioritize Homebrew\n\(exportCommand)\n")
                     logger.log("✅ Added specific python PATH export to Catalyst config.")
                 } else {
                     logger.log("ℹ️ PATH export already exists in config.")
                 }
                 
                 _ = ShellConfigManager.shared.ensureCatalystSourced()
                 
                 logger.log("✅ Fix applied. Changes will take effect in NEW terminal sessions.")
                 return true
             } catch {
                 logger.log("❌ Failed to update shell config: \(error.localizedDescription)")
                 return false
             }
        }
        
        return false
    }
}
