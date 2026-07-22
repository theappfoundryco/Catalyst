import SwiftUI
/// A view for managing SSH key pairs, verifying permissions, and copying public keys.
///
/// ```swift
/// SSHKeyView(vm: sshKeyViewModel)
/// ```
struct SSHKeyView: View {
    @ObservedObject var vm: SSHKeyViewModel

    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                MasterHeaderView(
                    title: "SSH Keys",
                    subtitle: "Manage, Generate & Secure Your Keys",
                    image: "key.fill",
                    color: .indigo
                )

                switch vm.state {
                case .idle, .scanning where vm.report == nil:
                    scanningView
                default:
                    if let report = vm.report {
                        content(report)
                    } else {
                        scanningView
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("SSH Keys")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if vm.state == .scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await vm.scan() } } label: {
                        Label("Re-Scan", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .task { if vm.state == .idle { await vm.scan() } }
    }

    @ViewBuilder
    /// Renders the active layout based on the loaded cryptographic key state.
    /// - Parameter report: The compiled filesystem state capturing SSH metadata.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func content(_ report: SSHKeyReport) -> some View {
        VStack(spacing: 24) {
            if !report.dirPermsOK && report.dirExists {
                BannerView(.warning, message: "Your ~/.ssh directory permissions are too open. SSH may refuse your keys. Tap Fix to set them to 700.")
                    .overlay(alignment: .trailing) {
                        Button("Fix") { Task { await vm.fixDirPermissions() } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .padding(.trailing, 28)
                    }
            }

            generateCard

            keysCard(report)
        }
    }

    // MARK: - Generate card

    private var generateCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardHeader("Generate New Key", subtitle: "Creates a key pair in ~/.ssh", icon: "key.horizontal.fill")

            // Key Type
            VStack(alignment: .leading, spacing: 6) {
                Text("Key Type").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                Picker("Key Type", selection: $vm.newKeyType) {
                    Text("Ed25519 (recommended)").tag("ed25519")
                    Text("RSA 4096").tag("rsa")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: vm.newKeyType) { _ in vm.syncDefaultName() }
            }

            CompactInputField(label: "File Name", icon: "doc",
                              placeholder: "e.g. id_ed25519", text: $vm.newKeyName)

            CompactInputField(label: "Comment", icon: "text.quote",
                              placeholder: "e.g. you@host", text: $vm.newKeyComment)

            CompactInputField(label: "Passphrase (optional)", icon: "lock",
                              placeholder: "Leave blank for no passphrase",
                              text: $vm.newKeyPassphrase, isSecure: true)

            HStack {
                if let msg = vm.generationMessage {
                    Label(msg, systemImage: vm.generationSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(vm.generationSucceeded ? .green : .orange)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    Task { await vm.generate() }
                } label: {
                    HStack {
                        if vm.isGenerating { ProgressView().controlSize(.small) }
                        Image(systemName: "key.horizontal.fill")
                        Text("Generate")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isGenerating)
            }
        }
        .cardStyle()
    }

    // MARK: - Keys list

    /// - Parameter report: The compiled filesystem state capturing SSH metadata.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func keysCard(_ report: SSHKeyReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("Your Keys", subtitle: "\(report.keys.count) key pair(s) in ~/.ssh", icon: "list.bullet.rectangle.fill")

            if report.keys.isEmpty {
                Text(report.dirExists ? "No SSH keys found. Generate one above to get started."
                                      : "No ~/.ssh directory yet. Generate a key to create it.")
                    .font(.subheadline).foregroundColor(.secondary)
            } else {
                ForEach(report.keys) { key in
                    keyRow(key)
                    if key.id != report.keys.last?.id { SectionDivider() }
                }
            }
        }
        .cardStyle()
    }

    /// Constructs a detailed visual breakdown for a single discovered SSH key.
    /// - Parameter key: The structured property block representing a distinct cryptographic key.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func keyRow(_ key: SSHKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").foregroundColor(.indigo)
                Text(key.name).font(.subheadline).fontWeight(.semibold)

                Text(key.type)
                    .font(.caption2).fontWeight(.bold)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.indigo.opacity(0.12)).foregroundColor(.indigo).cornerRadius(4)

                Text("\(key.bits)-bit").font(.caption2).foregroundColor(.secondary)

                if key.isWeak {
                    Text("Weak").font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15)).foregroundColor(.orange).cornerRadius(4)
                }

                if key.privatePermsOK == false {
                    Text("Perms 600?").font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red.opacity(0.15)).foregroundColor(.red).cornerRadius(4)
                }

                Spacer()
            }

            Text(key.fingerprint)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.middle)

            if !key.comment.isEmpty {
                Text(key.comment).font(.caption2).foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                if vm.busyItemID == key.id {
                    ProgressView().controlSize(.small)
                }
                Button {
                    vm.copyPublicKey(key)
                } label: {
                    Label(vm.copiedKeyID == key.id ? "Copied!" : "Copy Public Key",
                          systemImage: vm.copiedKeyID == key.id ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.secondaryAction)
                .disabled(!key.hasPublicKey)

                Button {
                    vm.reveal(key)
                } label: {
                    Label("Reveal", systemImage: "magnifyingglass")
                }
                .buttonStyle(.secondaryAction)

                if key.privatePermsOK == false {
                    Button {
                        Task { await vm.fixKeyPermissions(key) }
                    } label: {
                        Label("Fix Perms", systemImage: "lock.shield")
                    }
                    .buttonStyle(.destructiveAction)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Shared

    /// - Parameters:
    ///   - title: The primary display banner.
    ///   - subtitle: Supplemental descriptive text.
    ///   - icon: The associated SF Symbol glyph.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func cardHeader(_ title: String, subtitle: String, icon: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Scanning ~/.ssh…").font(.headline)
        }.padding(40).frame(maxWidth: .infinity).padding(.horizontal)
    }
}
