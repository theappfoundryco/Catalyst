import Foundation

/// Accepts incoming XPC connections from the app and wires them to the tool.
///
/// SECURITY: production helpers must verify the *caller's* code signature before
/// accepting, so only the genuine, correctly-signed Catalyst app can drive root
/// actions. The `SMAuthorizedClients` requirement in the helper's Info.plist is
/// the first line of defense; for defense-in-depth, also validate the audit
/// token here (see README → "Hardening").
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: CatalystHelperProtocol.self)
        newConnection.exportedObject = CatalystHelperTool()
        newConnection.resume()
        return true
    }
}

/// The privileged worker. Runs as root; keep its surface minimal.
final class CatalystHelperTool: NSObject, CatalystHelperProtocol {

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

    func getVersion(withReply reply: @escaping (String) -> Void) {
        reply(CatalystHelperConstants.helperVersion)
    }
}
