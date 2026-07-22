import Foundation

/// A diagnostic checker that inspects local network port availability and basic internet connectivity.
///
/// Ensures common development ports are free from orphan processes and verifies basic network reachability.
struct NetworkDoctor: Doctor {
    var category: HealthCategory { .network }


    /// Checks common developer ports to see if they are occupied by zombie processes and tests DNS resolution.
    ///
    /// **Flow:**
    /// 1. Iterates standard ports (3000, 8080, 5000, etc.) executing `lsof -i -sTCP:LISTEN`.
    /// 2. Identifies exact process names bound to any occupied socket ports, ignoring macOS specifics like `ControlCenter`.
    /// 3. Executes an ICMP ping to a highly available external IP (`8.8.8.8`) to confirm WAN connectivity.
    ///
    /// - Returns: An array of `HealthIssue` detailing port conflicts or network outages.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        let commonPorts = [3000, 8000, 8080, 5000, 5001]
        
        for port in commonPorts {
            do {
                let result = try await AsyncProcessRunner.shared.run(command: "lsof -i :\(port) -sTCP:LISTEN -t")
                if result.succeeded && !result.stdout.isEmpty {
                    let pid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    let nameResult = try await AsyncProcessRunner.shared.run(command: "ps -p \(pid) -o comm=")
                    let name = nameResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "/").last ?? "Unknown"
                    
                    if port == 5000 && name == "ControlCenter" {
                        continue
                    }
                    
                    issues.append(HealthIssue(
                        category: .network,
                        title: "Port \(port) In Use",
                        description: "Process '\(name)' (PID: \(pid)) is occuping port \(port). This might block new servers.",
                        severity: .info,
                        autoFixAvailable: true,
                        fixID: .portInUse
                    ))
                }
            } catch {
            }
        }
        
        do {
            let trace = try await AsyncProcessRunner.shared.run(command: "ping -c 1 -W 1000 8.8.8.8 | grep 'time='")
            if trace.succeeded {
            } else {
                 issues.append(HealthIssue(
                    category: .network,
                    title: "DNS / Internet Issues",
                    description: "Could not ping 8.8.8.8. Check your internet connection.",
                    severity: .warning,
                    autoFixAvailable: false
                ))
            }
        } catch {}
        
        return issues
    }
    
    /// Attempts to forcefully terminate processes occupying required development ports.
    ///
    /// **Gotchas:**
    /// Requires executing `kill -9` dynamically derived from string parsing the `HealthIssue` title.
    ///
    /// - Parameter issue: The network conflict issue containing the port.
    /// - Returns: A boolean indicating if the conflicting process was successfully terminated.
    func fix(_ issue: HealthIssue) async -> Bool {
        /// Routed by fixID; the port is still parsed from the title text.
        ///
        /// **Gotchas:** The fix mechanism relies on brittle string parsing of the issue title because the `HealthIssue` struct lacks a dedicated payload field.
        if issue.fixID == .portInUse {
            if let portStr = issue.title.components(separatedBy: " ").dropFirst().first, let port = Int(portStr) {
                 do {
                    let result = try await AsyncProcessRunner.shared.run(command: "lsof -i :\(port) -t | xargs kill -9")
                    return result.succeeded
                 } catch { return false }
            }
        }
        return false
    }
}
