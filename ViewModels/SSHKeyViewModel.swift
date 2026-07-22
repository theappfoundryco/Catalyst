import Foundation
import SwiftUI
import AppKit
import Combine

/// A view model governing SSH key management and security validation.
///
/// It communicates with the `SSHKeyService` to enumerate local `~/.ssh` identities,
/// evaluate file/directory permissions against OpenSSH requirements, and generate new keys.
///
/// **Caveats:**
/// - `fixDirPermissions` and `fixKeyPermissions` rely heavily on the file system. They run `chmod`
///   synchronously (via async wrapper) to restore safe defaults.
///
/// ```swift
/// @StateObject var vm = SSHKeyViewModel()
/// await vm.scan()
/// ```
@MainActor
final class SSHKeyViewModel: ObservableObject {
    /// The overall scanning lifecycle state.
    enum State: Equatable {
        case idle
        case scanning
        case ready
    }

    /// The current scanning state.
    @Published var state: State = .idle
    /// The aggregated list of keys and global `.ssh` directory health.
    @Published var report: SSHKeyReport?
    /// The ID of the key currently undergoing a permission fix (used for loading spinners).
    @Published var busyItemID: String?

    // Generation form
    /// The algorithm type for the new key (e.g. `ed25519` or `rsa`).
    @Published var newKeyType: String = "ed25519"
    /// The filename (defaulting to e.g. `id_ed25519`).
    @Published var newKeyName: String = "id_ed25519"
    /// A user-provided comment embedded in the public key.
    @Published var newKeyComment: String = ""
    /// An optional passphrase for the private key.
    @Published var newKeyPassphrase: String = ""
    /// Indicates whether `ssh-keygen` is actively running.
    @Published var isGenerating = false
    /// Feedback from the generation process.
    @Published var generationMessage: String?
    /// Indicates if the last generation attempt was successful.
    @Published var generationSucceeded = false

    /// Transient "Copied!" feedback keyed by key id.
    @Published var copiedKeyID: String?

    private let service = SSHKeyService.shared
    private let logger = Logger.shared

    init() {
        // Default comment to user@host.
        let user = NSUserName()
        let host = Host.current().localizedName ?? "mac"
        newKeyComment = "\(user)@\(host)"
    }

    /// Sweeps `~/.ssh` for valid identities and evaluates file permissions.
    func scan() async {
        if report == nil { state = .scanning }
        let newReport = await service.scan()
        self.report = newReport
        self.state = .ready
        logger.log("🔑 SSH scan: \(newReport.keys.count) key(s), dir perms \(newReport.dirPermsOK ? "OK" : "needs fix")")
    }

    /// Invokes `ssh-keygen` with the form's parameters.
    ///
    /// **Gotchas:**
    /// - Binds the `generationSucceeded` and `generationMessage` states to fuel the UI alert.
    /// - Automatically triggers a background re-scan upon success to reveal the newly minted key.
    func generate() async {
        isGenerating = true
        generationMessage = nil
        defer { isGenerating = false }

        let result = await service.generate(
            type: newKeyType,
            fileName: newKeyName,
            comment: newKeyComment,
            passphrase: newKeyPassphrase
        )
        generationSucceeded = result.success
        generationMessage = result.message
        logger.log(result.success ? "🔑 \(result.message)" : "❌ SSH keygen: \(result.message)")
        if result.success {
            newKeyPassphrase = ""
            await scan()
        }
    }

    /// Copies a specific public key directly to the macOS general pasteboard.
    ///
    /// - Parameter key: The model containing the parsed `.pub` contents.
    func copyPublicKey(_ key: SSHKey) {
        guard let content = key.publicKeyContent, !content.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(content, forType: .string)
        copiedKeyID = key.id
        logger.log("🔑 Copied public key \(key.name) to clipboard")
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedKeyID == key.id { copiedKeyID = nil }
        }
    }

    /// Opens the specified key's directory in the macOS Finder.
    ///
    /// - Parameter key: The target key model.
    func reveal(_ key: SSHKey) {
        let path = key.publicPath ?? key.privatePath
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Re-applies `chmod 700` to `~/.ssh` and re-scans.
    func fixDirPermissions() async {
        busyItemID = "dir"
        defer { busyItemID = nil }
        _ = await service.fixDirPermissions()
        await scan()
    }

    /// Re-applies safe defaults to a specific private/public keypair and re-scans.
    ///
    /// - Parameter key: The compromised key requiring `chmod 600`.
    func fixKeyPermissions(_ key: SSHKey) async {
        busyItemID = key.id
        defer { busyItemID = nil }
        _ = await service.fixKeyPermissions(key)
        await scan()
    }

    /// Keeps the default filename in sync with the chosen encryption algorithm.
    ///
    /// **Rationale:**
    /// Replaces `id_ed25519` with `id_rsa` dynamically as the user toggles the form UI, but
    /// explicitly *ignores* the sync if they have manually typed a custom filename.
    func syncDefaultName() {
        let knownDefaults = ["id_ed25519", "id_rsa"]
        if knownDefaults.contains(newKeyName) {
            newKeyName = (newKeyType == "rsa") ? "id_rsa" : "id_ed25519"
        }
    }
}
