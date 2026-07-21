import Foundation
import AppKit

/// A system execution conduit directing commands to macOS graphical terminal interfaces securely.
///
/// Ensures targeted execution environments are handled without AppleScript vulnerabilities.
@MainActor
final class TerminalService {
    static let shared = TerminalService()
    
    private let logger = Logger.shared
    
    private init() {}
    
    /// Requests process evaluation within the native Terminal context by delegating through secure inter-process streams.
    ///
    /// - Parameters:
    ///   - command: The explicit bash configuration requesting system invocation.
    ///   - activate: A boolean specifying if the Terminal instance immediately inherits system focus.
    func runCommand(_ command: String, activate: Bool = true) {
        if command.rangeOfCharacter(from: .newlines) != nil || command.rangeOfCharacter(from: .controlCharacters) != nil {
            logger.log("❌ TerminalService: Command rejected due to invalid characters")
            return
        }

        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        
        let activationScript = activate ? "activate" : ""
        
        let appleScript = """
        tell application "Terminal"
            \(activationScript)
            if (count of windows) > 0 then
                try
                    do script "\(escapedCommand)" in front window
                on error
                    do script "\(escapedCommand)"
                end try
            else
                do script "\(escapedCommand)"
            end if
        end tell
        """
        
        executeAppleScript(appleScript, description: "Run command")
    }
    
    /// Funnels string commands demanding sequential or interactive inputs into terminal streams explicitly.
    ///
    /// - Parameter command: An interactive executable mapping bound for the active user context.
    func runInteractiveCommand(_ command: String) {
         runCommand(command)
    }
    
    private func executeAppleScript(_ script: String, description: String) {
        guard let scriptObject = NSAppleScript(source: script) else {
            logger.log("❌ Failed to create NSAppleScript for: \(description)")
            return
        }
        
        var error: NSDictionary?
        scriptObject.executeAndReturnError(&error)

        if let error = error {
            logger.log("❌ AppleScript error (\(description)): \(error)")
            // -1743 = errAEEventNotPermitted: the user hasn't granted (or has denied) Automation
            // access to Terminal. The system only prompts on the FIRST send; once denied it stays
            // denied silently, so send the user straight to the setting to fix it.
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                openAutomationPrivacySettings()
            }
        } else {
            logger.log("✅ TerminalService: \(description)")
        }
    }

    /// Opens System Settings → Privacy & Security → Automation so the user can allow Catalyst
    /// to control Terminal after a -1743 denial (no re-prompt is issued once denied).
    private func openAutomationPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}
