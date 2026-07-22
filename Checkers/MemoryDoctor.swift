import Foundation

/// A diagnostic tool that evaluates system memory pressure and identifies memory-intensive developer processes.
struct MemoryDoctor: Doctor {
    var category: HealthCategory { .memory }


    /// Scans the system for high swap usage and excessive RAM consumption by developer tools.
    ///
    /// **Flow:**
    /// 1. Reads swap boundaries from `sysctl vm.swapusage`.
    /// 2. Parses active memory footprints using `ps -axm -o rss,comm`.
    /// 3. Filters high-consumption instances matching patterns like Java, Node, Docker, and Xcode.
    ///
    /// - Returns: An array of `HealthIssue` objects highlighting memory hogs or high swap pressure.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        
        if let swap = await getSwapUsage(), swap > 1024 {
            let swapGB = String(format: "%.1f", Double(swap) / 1024.0)
            issues.append(HealthIssue(
                category: .memory,
                title: "High Swap Usage (\(swapGB) GB)",
                description: "Your Mac is using significant swap memory. This slows down development tools.",
                severity: .warning,
                autoFixAvailable: false
            ))
        }
        
        let bigProcs = await getTopDevProcesses()
        for proc in bigProcs {
            if proc.ramMB > 4096 {
                let gb = String(format: "%.1f", Double(proc.ramMB) / 1024.0)
                issues.append(HealthIssue(
                    category: .memory,
                    title: "Memory Hog: \(proc.name)",
                    description: "\(proc.name) is consuming \(gb) GB of RAM. Consider restarting it if idle.",
                    severity: .info, 
                    autoFixAvailable: false
                ))
            }
        }
        
        return issues
    }
    
    /// Attempts to programmatically resolve memory pressure issues.
    ///
    /// **Gotchas:**
    /// Force-killing arbitrary development tasks (`SIGKILL`) causes state loss in simulators and IDEs. Auto-fix is intentionally restricted.
    ///
    /// - Parameter issue: The memory issue identified.
    /// - Returns: A boolean indicating if the remediation was successful (always `false` for memory bounds).
    func fix(_ issue: HealthIssue) async -> Bool {
        return false
    }
    
    /// Extracts current swapfile pressure metrics from `sysctl`.
    private func getSwapUsage() async -> Int? {
        guard let result = try? await AsyncProcessRunner.shared.run(command: "sysctl vm.swapusage"), result.succeeded else { return nil }
        
        let output = result.stdout
        if let range = output.range(of: "used = ") {
            let rest = output[range.upperBound...]
            let component = rest.prefix { $0 != " " && $0 != "M" && $0 != "G" }
            if let value = Double(String(component)) {
                
                 if rest.contains("G") {
                    return Int(value * 1024)
                } else if rest.contains("M") {
                    return Int(value)
                }
            }
        }
        return nil
    }
    
    /// Represents the memory footprint of a running process.
    struct ProcessMem {
        let name: String
        let ramMB: Int
    }
    
    /// Collects the highest resident-memory consuming processes via `ps`.
    private func getTopDevProcesses() async -> [ProcessMem] {
        guard let result = try? await AsyncProcessRunner.shared.run(command: "ps -axm -o rss,comm"), result.succeeded else { return [] }
        
        var procs: [ProcessMem] = []
        let lines = result.stdout.components(separatedBy: .newlines)
        
        for line in lines.dropFirst() {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
            guard let rssStr = parts.first, let rssKB = Int(rssStr) else { continue }
            
            let mb = rssKB / 1024
            let path = parts.dropFirst().joined(separator: " ")
            let name = URL(fileURLWithPath: path).lastPathComponent
            
            let relevant = ["java", "node", "python3.10", "python3.11", "python3", "Docker", "Xcode", "Simulator", "qemu-system"]
            if relevant.contains(where: { name.contains($0) }) {
                procs.append(ProcessMem(name: name, ramMB: mb))
            }
        }
        
        return procs.sorted { $0.ramMB > $1.ramMB }
    }
}
