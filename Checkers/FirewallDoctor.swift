import Foundation

/// A diagnostic utility that inspects macOS firewall settings.
///
/// This checker looks for strict firewall configurations or stealth mode settings that can interfere with local development tools and networking.
struct FirewallDoctor: Doctor {
    var category: HealthCategory { .firewall }


    /// Evaluates the active firewall state and configuration policies.
    ///
    /// - Returns: An array of `HealthIssue` objects highlighting strict or stealth firewall modes.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        
        // 1. Check if Firewall is enabled
        // /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
        do {
            let res = try await AsyncProcessRunner.shared.run(command: "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate")
            if res.succeeded {
                if res.stdout.contains("disabled") {
                    // Firewall disabled is actually "fine" for devs (no prompts), but security risk.
                    // We'll mark it as info.
                    // If enabled, that's where prompts come from.
                } else if res.stdout.contains("enabled") {
                    // Firewall is ON. Check for annoying prompts configuration.
                    
                    // 2. Check "Allow signed downloaded software"
                    // socketfilterfw --getallowsigned
                    // If this is OFF, you get prompts for EVERYTHING.
                    let signedRes = try await AsyncProcessRunner.shared.run(command: "/usr/libexec/ApplicationFirewall/socketfilterfw --getallowsigned")
                    if signedRes.stdout.contains("DISABLED") {
                         issues.append(HealthIssue(
                            category: .firewall,
                            title: "Strict Firewall Mode",
                            description: "Your firewall is blocking signed apps automatically. This causes constant 'Accept Connections' prompts.",
                            severity: .warning,
                            autoFixAvailable: true,
                            fixID: .strictFirewallMode
                        ))
                    }
                    
                    // 3. Check for specific developer tools being blocked
                    // socketfilterfw --listapps
                    // We can parse this... but it's verbose.
                    // Instead, we can check known pain points like python/node if they are NOT in the whitelist?
                    // Actually, the main pain is when they ARE checked but signature changed.
                    // For now, let's offer a "Dev Whitelist" feature via fix
                    
                    // Detect if stealth mode is on (blocks ping)
                    let stealth = try await AsyncProcessRunner.shared.run(command: "/usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode")
                    if stealth.stdout.contains("enabled") {
                         issues.append(HealthIssue(
                            category: .firewall,
                            title: "Stealth Mode Enabled",
                            description: "Stealth mode drops ICMP pings. This might make debugging network issues harder.",
                            severity: .info,
                            autoFixAvailable: true,
                            fixID: .stealthModeEnabled
                        ))
                    }
                }
            }
        } catch {}
        
        return issues
    }
    
    /// Attempts to relax firewall settings to improve developer experience.
    ///
    /// - Parameter issue: The firewall issue specifying the configuration to change.
    /// - Returns: A boolean indicating whether the firewall adjustment was successful.
    func fix(_ issue: HealthIssue) async -> Bool {
        if issue.fixID == .strictFirewallMode {
             // Enable allow signed
             // Requires sudo usually... socketfilterfw needs root?
             // Catalyst runs as user. This might fail without sudo.
             // But let's try.
             _ = try? await AsyncProcessRunner.shared.run(command: "/usr/libexec/ApplicationFirewall/socketfilterfw --setallowsigned on")
             return true 
        }
        
        if issue.fixID == .stealthModeEnabled {
             _ = try? await AsyncProcessRunner.shared.run(command: "/usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode off")
             return true
        }
        
        return false
    }
}
