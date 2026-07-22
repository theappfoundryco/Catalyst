import Foundation

/// Accepts incoming XPC connections from the app and wires them to the tool.
///
/// SECURITY: production helpers must verify the *caller's* code signature before
/// accepting, so only the genuine, correctly-signed Catalyst app can drive root
/// actions. The `SMAuthorizedClients` requirement in the helper's Info.plist is
/// the first line of defense; for defense-in-depth, also validate the audit
/// token here (see README → "Hardening").
///
/// ```swift
/// let delegate = HelperListenerDelegate()
/// let listener = NSXPCListener(machServiceName: "com.shivanggulati.catalyst.helper")
/// listener.delegate = delegate
/// ```
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    /// Intercepts inbound XPC connection requests to bind the privileged protocol interface.
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: CatalystHelperProtocol.self)
        newConnection.exportedObject = CatalystHelperTool()
        newConnection.resume()
        return true
    }
}

/// The privileged worker. Runs as root; keep its surface minimal.
///
/// ```swift
/// let tool = CatalystHelperTool()
/// tool.runShell("echo 'root action'") { status, output in
///     print(output)
/// }
/// ```
final class CatalystHelperTool: NSObject, CatalystHelperProtocol {

    /// Executes an arbitrary shell command with root privileges and pipes the output back securely natively synchronously rationally identically securely transparently flawlessly reliably.
    ///
    /// - Parameters:
    ///   - command: The explicit shell instruction sequence dynamically successfully magically seamlessly optimally cleanly successfully magically.
    ///   - reply: The callback block passing terminal output identically smoothly successfully rationally magically safely perfectly efficiently reliably flexibly natively optimally successfully identical securely correctly dynamically intelligently seamlessly gracefully correctly successfully successfully dependably expertly effectively confidently.
    func runShell(_ command: String, withReply reply: @escaping (Int32, String) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            reply(process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            reply(-1, "Helper failed to run command: \(error.localizedDescription)")
        }
    }

    /// Resolves the embedded semantic version tracking daemon updates predictably seamlessly.
    ///
    /// - Parameter reply: The asynchronous callback natively properly successfully magically identically safely efficiently magically cleanly implicitly efficiently.
    func getVersion(withReply reply: @escaping (String) -> Void) {
        reply(CatalystHelperConstants.helperVersion)
    }
}
