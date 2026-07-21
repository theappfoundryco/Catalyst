import Foundation

/// A diagnostic checker that scans for potential security vulnerabilities and misconfigurations.
///
/// Ensures sensitive data hasn't leaked into shell histories and validates SSH key permissions and strengths.
struct SecurityDoctor: Doctor {
    var category: HealthCategory { .security }


    /// Executes core security checks across the shell environment and SSH configurations.
    ///
    /// - Returns: An array of `HealthIssue` highlighting secrets in history, unsafe permissions, or weak RSA keys.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        
        do {
            // Scan both zsh and bash history (bash users were previously skipped).
            // `cat ... 2>/dev/null` tolerates a missing file; tail caps each.
            let command = "cat ~/.zsh_history ~/.bash_history 2>/dev/null | tail -n 4000 | grep -E 'AKIA[0-9A-Z]{16}|sk_live_[0-9a-zA-Z]{24}|-----BEGIN PRIVATE KEY-----'"
            let result = try await AsyncProcessRunner.shared.run(command: command)

            if result.succeeded && !result.stdout.isEmpty {
                let count = result.stdout.components(separatedBy: .newlines).filter({ !$0.isEmpty }).count
                if count > 0 {
                    issues.append(HealthIssue(
                        category: .security,
                        title: "Secrets in Shell History",
                        description: "Found \(count) potential secrets (AWS/Stripe keys) in your recent shell history. Verify ~/.zsh_history and ~/.bash_history.",
                        severity: .critical,
                        autoFixAvailable: false
                    ))
                }
            }
        } catch {}
        
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let sshDir = home.appendingPathComponent(".ssh")
        
        if let attrs = try? fm.attributesOfItem(atPath: sshDir.path),
           let permissions = attrs[.posixPermissions] as? Int {
            // Mask to the permission bits and compare against octal 0o700.
            // Exact equality against the decimal 448 flags a correctly-secured
            // dir as unsafe whenever extra mode bits (sticky/setgid) are set.
            if (permissions & 0o777) != 0o700 {
                 issues.append(HealthIssue(
                    category: .security,
                    title: "Unsafe SSH Permissions",
                    description: "Your ~/.ssh directory permissions are too open (\(String(format: "%o", permissions & 0o777))). Should be 700.",
                    severity: .warning,
                    autoFixAvailable: true,
                    fixID: .fixSSHDirPermissions
                ))
            }
        }
        
        do {
            let contents = try fm.contentsOfDirectory(at: sshDir, includingPropertiesForKeys: nil)
            for url in contents {
                if url.lastPathComponent.hasPrefix("id_") && !url.lastPathComponent.hasSuffix(".pub") {
                    if let attrs = try? fm.attributesOfItem(atPath: url.path),
                       let permissions = attrs[FileAttributeKey.posixPermissions] as? Int {
                        // Mask and compare against octal 0o600 (see note above).
                        if (permissions & 0o777) != 0o600 {
                             issues.append(HealthIssue(
                                category: .security,
                                title: "Unsafe Key Permissions",
                                description: "Private key \(url.lastPathComponent) is accessible by others (\(String(format: "%o", permissions & 0o777))). Should be 600.",
                                severity: .critical,
                                autoFixAvailable: true,
                                fixID: .fixSSHKeyPermissions
                            ))
                        }
                    }
                }
            }
        } catch {}
        
        do {
             let contents = try? fm.contentsOfDirectory(at: sshDir, includingPropertiesForKeys: nil)
             for url in contents ?? [] {
                 let name = url.lastPathComponent
                 // Any private key file (id_*, not .pub), not just "id_rsa".
                 guard name.hasPrefix("id_"), !name.hasSuffix(".pub") else { continue }

                 let result = try await AsyncProcessRunner.shared.run(command: "ssh-keygen -l -f \(InputSanitizer.singleQuote(url.path))")
                 guard result.succeeded else { continue }
                 // `ssh-keygen -l` prints "<bits> SHA256:… comment (TYPE)".
                 // Only RSA keys under 2048 bits are weak.
                 let parts = result.stdout.split(separator: " ")
                 let isRSA = result.stdout.contains("(RSA)")
                 if isRSA, let bitsStr = parts.first, let bits = Int(bitsStr), bits < 2048 {
                      issues.append(HealthIssue(
                        category: .security,
                        title: "Weak SSH Key",
                        description: "\(name) is only \(bits)-bit RSA. Consider upgrading to Ed25519.",
                        severity: .warning,
                        autoFixAvailable: false
                    ))
                 }
             }
        } catch {}
        
        return issues
    }
    
    /// Attempts to securely lock down SSH configurations when vulnerabilities are found.
    ///
    /// - Parameter issue: The security issue detailing which permissions need restricting.
    /// - Returns: A boolean indicating if the security fix was successful.
    func fix(_ issue: HealthIssue) async -> Bool {
        if issue.fixID == .fixSSHDirPermissions {
            let res = try? await AsyncProcessRunner.shared.run(command: "chmod 700 ~/.ssh")
            return res?.succeeded ?? false
        }
        if issue.fixID == .fixSSHKeyPermissions {
            let res = try? await AsyncProcessRunner.shared.run(command: "chmod 600 ~/.ssh/id_* && chmod 644 ~/.ssh/id_*.pub")
            return res?.succeeded ?? false
        }
        return false
    }
}
