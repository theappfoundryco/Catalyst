import SwiftUI

struct ShortcutDetailView: View {
    let shortcutId: String
    @ObservedObject var viewModel: SmartShortcutsViewModel

    @State private var customName = ""
    @State private var nameCopied = false

    var isInstalled: Bool {
        viewModel.isInstalled(shortcutId)
    }

    /// The item metadata (icon/color/title/tagline) from the index.
    private var item: ShortcutItem? {
        viewModel.shortcuts.first { $0.id == shortcutId }
    }

    /// The function name the user will actually type: the installed custom name,
    /// or the live text they're entering, falling back to the shortcut's default.
    private func effectiveName(_ detail: ShortcutDetail) -> String {
        if isInstalled { return viewModel.getCustomName(shortcutId) ?? detail.original_name }
        let typed = customName.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? detail.original_name : typed
    }

    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 20) {
                if let detail = viewModel.detail {

                    if let item { heroCard(item) }

                    if isInstalled {
                        installedStatusCard
                    } else {
                        customNameCard(detail)
                    }

                    if !detail.dependencies.brew.isEmpty || !detail.dependencies.pip.isEmpty {
                        dependenciesCard(detail)
                    }

                    // Consolidated, name-aware content (usage/examples reflect the chosen name).
                    if let content = detail.content, !content.isEmpty {
                        ShortcutContentView(
                            content: content,
                            originalName: detail.original_name,
                            effectiveName: effectiveName(detail)
                        )
                    }

                    if viewModel.isInstalling {
                        VStack(spacing: 8) {
                            ProgressView("Installing…")
                            Text("Configuring shell…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .cardStyle()
                    }

                    installationOutputCard
                } else if let err = viewModel.detailError {
                    detailErrorCard(err)
                } else {
                    LoadingStateView("Loading…", verticalPadding: 60)
                        .cardStyle()
                }

                Spacer()
            }
            .padding(.vertical)
        }
        .navigationTitle(item?.title ?? viewModel.detail?.original_name ?? "Loading…")
        .task(id: shortcutId) {
            await viewModel.loadDetail(shortcutId: shortcutId)
        }
        .onDisappear {
            viewModel.resetDetail()
        }
        .alert("Name Conflict", isPresented: $viewModel.showingNameConflict) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("A function with this name already exists in your .zshrc. Please choose a different name.")
        }
    }

    // MARK: - Hero (identity)

    private func heroCard(_ item: ShortcutItem) -> some View {
        HStack(alignment: .center, spacing: 16) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorGradient(for: item.color))
                .frame(width: 54, height: 54)
                .overlay(
                    Image(systemName: item.icon)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.tagline)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            CategoryPill(title: item.category, isSelected: true, action: {})
        }
        .cardStyle()
    }

    // MARK: - Detail Error Card

    private func detailErrorCard(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await viewModel.loadDetail(shortcutId: shortcutId) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .labelStyle(.matched)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
        .cardStyle()
    }

    // MARK: - Installed Status Card

    private var installedStatusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 5) {
                Text("Installed")
                    .font(.headline)

                if let name = viewModel.getCustomName(shortcutId) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.callout.monospaced().weight(.medium))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(name, forType: .string)
                            nameCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { nameCopied = false }
                        } label: {
                            Image(systemName: nameCopied ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                                .foregroundColor(nameCopied ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy command name")
                    }
                }

                Text("Reopen Terminal to start using it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                Task { await viewModel.uninstallShortcut(shortcutId) }
            } label: {
                Text(viewModel.isInstalling ? "Uninstalling…" : "Uninstall")
            }
            .buttonStyle(.destructiveAction)
            .disabled(viewModel.isInstalling)
        }
        .cardStyle()
    }

    // MARK: - Custom Name Card

    private func customNameCard(_ detail: ShortcutDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Function name")
                .font(.headline)

            SectionDivider()

            HStack(spacing: 12) {
                // The app's canonical text input (same look/behaviour as every other field).
                CompactInputField(
                    icon: "terminal",
                    placeholder: "Enter function name",
                    text: $customName,
                    onSubmit: {
                        guard !customName.isEmpty, !viewModel.isInstalling else { return }
                        Task { await viewModel.installShortcut(detail, shortcutId: shortcutId, customName: customName) }
                    }
                )

                Button {
                    Task { await viewModel.installShortcut(detail, shortcutId: shortcutId, customName: customName) }
                } label: {
                    Text("Install Shortcut")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .disabled(customName.isEmpty || viewModel.isInstalling)
                .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Default: \(detail.original_name) • letters, numbers, dashes, underscores")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .cardStyle()
        .onAppear {
            if customName.isEmpty {
                customName = detail.original_name
            }
        }
    }

    // MARK: - Dependencies Card

    private func dependenciesCard(_ detail: ShortcutDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Dependencies", systemImage: "shippingbox")
                .labelStyle(.matched)
                .font(.headline)

            SectionDivider()

            WrapChips(
                brew: detail.dependencies.brew,
                pip: detail.dependencies.pip
            )

            Text("Installed automatically when you add this shortcut.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .cardStyle()
    }

    // MARK: - Installation Output Card

    // The streamed install log was removed from the detail page for a cleaner view;
    // only a failure banner remains so errors still surface inline.
    private var installationOutputCard: some View {
        ErrorBanner(message: $viewModel.installError)
    }

    // MARK: - Helpers

    private func colorGradient(for color: String) -> LinearGradient {
        let colors: [Color] = {
            switch color {
            case "orange": return [.orange, .red]
            case "blue":   return [.blue, .cyan]
            case "purple": return [.purple, .pink]
            case "green":  return [.green, .mint]
            case "red":    return [.red, .pink]
            case "yellow": return [.yellow, .orange]
            case "cyan":   return [.cyan, .blue]
            default:       return [.gray, .secondary]
            }
        }()
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Compact dependency chips (Homebrew / pip) laid out in a simple flowing row.
private struct WrapChips: View {
    let brew: [String]
    let pip: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !brew.isEmpty {
                chipRow(title: "Homebrew", icon: "mug.fill", tint: .orange, items: brew)
            }
            if !pip.isEmpty {
                chipRow(title: "pip", icon: "shippingbox.fill", tint: .blue, items: pip)
            }
        }
    }

    private func chipRow(title: String, icon: String, tint: Color, items: [String]) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Label(title, systemImage: icon)
                .labelStyle(.matched)
                .font(.caption.weight(.semibold))
                .foregroundColor(tint)
            ForEach(items, id: \.self) { pkg in
                Text(pkg)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(tint.opacity(0.12)))
            }
            Spacer(minLength: 0)
        }
    }
}
