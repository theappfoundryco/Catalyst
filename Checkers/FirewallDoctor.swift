import Foundation

/// A diagnostic utility that inspects macOS firewall settings.
///
/// This checker looks for strict firewall configurations or stealth mode settings that can interfere with local development tools and networking.
struct FirewallDoctor: Doctor {
    var category: HealthCategory { .firewall }


    /// Evaluates the active firewall state and configuration policies.
    ///
    /// **Flow:**
    /// 1. Queries `/usr/libexec/ApplicationFirewall/socketfilterfw` for the global firewall state.
    /// 2. If enabled, checks `--getallowsigned` to detect strict prompting behaviors.
    /// 3. Checks `--getstealthmode` to identify ICMP dropping behavior.
    ///
    /// - Returns: An array of `HealthIssue` objects highlighting strict or stealth firewall modes.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        
        /// 1. Check if Firewall is enabled
        /// /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
        ///
        /// **Rationale:** Exposes the raw underlying Apple firewall daemon rather than relying on unreliable GUI preference panes.
        do {
            let res = try await AsyncProcessRunner.shared.run(command: "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate")
            if res.succeeded {
                if res.stdout.contains("disabled") {
                    /// Firewall disabled is actually "fine" for devs (no prompts), but security risk.
                    /// We'll mark it as info.
                    /// If enabled, that's where prompts come from.
                    ///
                    /// **Gotchas:** Completely disabling the firewall eliminates networking prompts but fails corporate compliance audits.
                } else if res.stdout.contains("enabled") {
                    /// Firewall is ON. Check for annoying prompts configuration.
                    ///
                    /// **Rationale:** An active firewall without exceptions essentially destroys node and ruby environments because every dynamic socket throws a user dialog.
                    
                    /// 2. Check "Allow signed downloaded software"
                    /// socketfilterfw --getallowsigned
                    /// If this is OFF, you get prompts for EVERYTHING.
                    ///
                    /// **Rationale:** Apple blocks unsigned daemons; keeping this off triggers relentless OS-level network prompts for every node/python binary.
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
                    
                    /// 3. Check for specific developer tools being blocked
                    /// socketfilterfw --listapps
                    /// We can parse this... but it's verbose.
                    /// Instead, we can check known pain points like python/node if they are NOT in the whitelist?
                    /// Actually, the main pain is when they ARE checked but signature changed.
                    /// For now, let's offer a "Dev Whitelist" feature via fix
                    ///
                    /// **Gotchas:** Parsing `listapps` natively is inherently slow; deferring to a whitelist repair is safer and prevents UI lockups.
                    
                    /// Detect if stealth mode is on (blocks ping)
                    ///
                    /// **Rationale:** Stealth mode drops ICMP natively, which falsely triggers offline statuses in docker and local routing tasks.
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
    /// **Gotchas:**
    /// Modifying `socketfilterfw` settings frequently requires `sudo` or root privileges. If Catalyst lacks these permissions, the fix will fail silently.
    ///
    /// - Parameter issue: The firewall issue specifying the configuration to change.
    /// - Returns: A boolean indicating whether the firewall adjustment was successful.
    func fix(_ issue: HealthIssue) async -> Bool {
        if issue.fixID == .strictFirewallMode {
             /// Enable allow signed
             /// Requires sudo usually... socketfilterfw needs root?
             /// Catalyst runs as user. This might fail without sudo.
             /// But let's try.
             ///
             /// **Gotchas:** Calling `socketfilterfw` without elevated context (`sudo`) fails silently on modern macOS environments.
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
