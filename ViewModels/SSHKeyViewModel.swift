import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class SSHKeyViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case scanning
        case ready
    }

    @Published var state: State = .idle
    @Published var report: SSHKeyReport?
    @Published var busyItemID: String?

    // Generation form
    @Published var newKeyType: String = "ed25519"
    @Published var newKeyName: String = "id_ed25519"
    @Published var newKeyComment: String = ""
    @Published var newKeyPassphrase: String = ""
    @Published var isGenerating = false
    @Published var generationMessage: String?
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

    func scan() async {
        if report == nil { state = .scanning }
        let newReport = await service.scan()
        self.report = newReport
        self.state = .ready
        logger.log("🔑 SSH scan: \(newReport.keys.count) key(s), dir perms \(newReport.dirPermsOK ? "OK" : "needs fix")")
    }

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

    func reveal(_ key: SSHKey) {
        let path = key.publicPath ?? key.privatePath
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func fixDirPermissions() async {
        busyItemID = "dir"
        defer { busyItemID = nil }
        _ = await service.fixDirPermissions()
        await scan()
    }

    func fixKeyPermissions(_ key: SSHKey) async {
        busyItemID = key.id
        defer { busyItemID = nil }
        _ = await service.fixKeyPermissions(key)
        await scan()
    }

    /// Keep the default filename in sync with the chosen type (only when the
    /// user hasn't typed a custom name).
    func syncDefaultName() {
        let knownDefaults = ["id_ed25519", "id_rsa"]
        if knownDefaults.contains(newKeyName) {
            newKeyName = (newKeyType == "rsa") ? "id_rsa" : "id_ed25519"
        }
    }
}
