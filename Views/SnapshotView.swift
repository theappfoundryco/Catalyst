/// CatalystSnapshot screen. Mirrors the Cruft Sweeper grammar: a top-level
/// `Group` that switches between distinct full states (Landing → Working →
/// Capture-ready / Restore-plan), cards use `cardStyle()`, and the restore plan
/// uses a `ZStack`-anchored sticky action bar.
/// Color language follows the app: blue is the screen accent, domain colors
/// come from what those domains use elsewhere (brew orange, pip/projects blue,
/// shell/git purple), and green/orange/red stay semantic.

import SwiftUI
/// The main view for the Snapshot & Migrate feature, managing the flow between landing, capture, and restore states.
///
/// ```swift
/// SnapshotView(vm: snapshotViewModel)
/// ```
struct SnapshotView: View {
    @ObservedObject var vm: SnapshotViewModel

    var body: some View {
        // The import bar is a LAYOUT SIBLING of the content, not an overlay.
        //
        // It used to be `.overlay(alignment: .top)` on the whole screen, which
        // anchors it just under the title bar and floats it *on top of* whatever is
        // behind — so it sat over the first Migrate card. In a `VStack` it occupies
        // its own row and pushes the content down instead, which is what a loading
        // bar should do. Import stays non-blocking either way (the full-window
        // working view remains reserved for capture / "Scanning this Mac").
        VStack(spacing: 0) {
            if vm.isImporting {
                SnapshotImportBar(label: vm.workingLabel)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Group {
                if vm.isWorking && !vm.isImporting && !vm.hasCapture && !vm.hasPlan {
                    SnapshotWorkingView(label: vm.workingLabel, tint: vm.workingTint)
                } else if vm.hasCapture {
                    SnapshotCaptureReadyView(vm: vm)
                } else if vm.hasPlan {
                    SnapshotRestorePlanView(vm: vm)
                } else {
                    SnapshotLandingView(vm: vm)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.isImporting)
        .navigationTitle("Snapshot & Migrate")
        // Encryption is asked for at the moment of capture — a card on the landing
        // page was too easy to scroll past.
        .sheet(isPresented: $vm.isShowingCaptureSheet) {
            SnapshotSecretsCaptureSheet(
                passphrase: $vm.capturePassphrase,
                isWorking: vm.isWorking,
                onCapture: { Task { await vm.captureThisMac() } },
                onCancel: { vm.isShowingCaptureSheet = false }
            )
        }
        // Standalone unlock — reachable without importing, diffing, or restoring.
        .sheet(isPresented: $vm.isShowingUnlockSheet) {
            SnapshotSecretsUnlockSheet(
                count: vm.unlockSnapshot?.secrets?.count ?? 0,
                passphrase: $vm.unlockPassphrase,
                validation: vm.unlockValidation,
                result: vm.unlockResult,
                isWorking: vm.isWorking,
                onValidate: { Task { await vm.validateUnlockPassphrase() } },
                onApply: { Task { await vm.applyStandaloneUnlock() } },
                onCancel: { vm.dismissUnlockSheet() }
            )
        }
        .task { await vm.refreshPendingSecrets() }
    }
}

/// Slim, non-blocking loading bar shown while an imported snapshot is read +
/// diffed. The bar eases toward 100% over 10s — a comfortable ceiling, since the
/// import really finishes in a few seconds, at which point it's dismissed. It is
/// deliberately never "done" on its own: progress here is genuinely unknown, and a
/// bar that parks just short of the end is honest about that.
private struct SnapshotImportBar: View {
    let label: String
    @State private var progress: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(label.isEmpty ? "Reading snapshot…" : label)
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            ProgressView(value: min(progress, 1))
                .tint(.blue)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear {
            progress = 0
            withAnimation(.linear(duration: 10)) { progress = 1 }
        }
    }
}

// MARK: - Shared

/// Maps a section's declared color name onto the app palette. Only colors the
/// app already uses for these domains — nothing new.
/// - Parameter name: The semantic identifier attached to the snapshot block.
/// - Returns: A derived UI color representation.
private func sectionColor(_ name: String) -> Color {
    switch name {
    case "orange": return .orange
    case "purple": return .purple
    case "blue": return .blue
    default: return .blue
    }
}

/// The one sticky footer bar used across this feature — same chrome as Cruft
/// Sweeper's delete bar: a `SectionDivider`, then a padded row on the control
/// background with a headline title + caption subtitle on the left and actions
/// pinned right. Reused by capture-export and restore so all footers match.
private struct SnapshotFooterBar<Buttons: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: 0) {
            SectionDivider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                buttons
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
}

// MARK: - Landing

private struct SnapshotLandingView: View {
    @ObservedObject var vm: SnapshotViewModel

    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                MasterHeaderView(
                    title: "Snapshot & Migrate",
                    subtitle: "Capture this Mac's dev environment into one portable file, then reproduce it on a new Mac.",
                    image: "arrow.triangle.2.circlepath.circle.fill",
                    color: .blue
                )

                ErrorBanner(message: $vm.errorMessage)

                /// Two large, illustrated action cards — each carries a gradient
                /// badge, a flow motif, and the real domain chips this feature moves.
                ///
                /// **Rationale:** Hero cards with explicit domain chips immediately communicate the scope of the snapshot feature to wary users.
                LandingAction(
                    icon: "camera.fill",
                    accent: .green,
                    title: "Capture this Mac",
                    tagline: "One file. Your whole setup.",
                    description: "Scan Homebrew, Python + pip, shell config, SmartShortcuts, git identity, and tracked projects into one shareable file — saved wherever you choose.",
                    buttonTitle: "Capture Snapshot",
                    buttonIcon: "camera.fill",
                    disabled: vm.isWorking
                ) { vm.beginCapture() }

                /// Surfaces itself only when there's unfinished business — secrets
                /// that were restored as placeholders and never unlocked.
                ///
                /// **Rationale:** Contextual visibility ensures users aren't confused by a "Decrypt Secrets" button when their environment is already fully unlocked.
                if vm.pendingSecretPlaceholders > 0 {
                    SnapshotSecretsPendingCard(
                        count: vm.pendingSecretPlaceholders,
                        disabled: vm.isWorking,
                        onUnlock: { Task { await vm.beginStandaloneUnlock() } }
                    )
                }

                LandingAction(
                    icon: "square.and.arrow.down.fill",
                    accent: .blue,
                    title: "Restore from a Snapshot",
                    tagline: "Rebuild a Mac in minutes.",
                    description: "Open a .catalystsnapshot file, preview exactly what differs from this Mac, dry-run it, then restore item by item.",
                    buttonTitle: "Import Snapshot…",
                    buttonIcon: "square.and.arrow.down",
                    disabled: vm.isWorking
                ) { Task { await vm.importSnapshot() } }

                /// Compact privacy footnote — wraps to one line when the window is
                /// wide enough, otherwise flows to two.
                ///
                /// **Rationale:** Proactively addressing telemetry and cloud concerns at the bottom of the hero screen prevents users from abandoning the flow due to security fears.
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Metadata & public config only — no passwords, tokens, SSH keys, or .env files. All on your Mac.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
            }
            .padding(.vertical)
        }
    }

}

/// A large landing card: a gradient icon badge, title + accent tagline, a short
/// description, the real domain chips this feature moves, and a tinted button.
private struct LandingAction: View {
    let icon: String
    let accent: Color
    let title: String
    let tagline: String
    let description: String
    let buttonTitle: String
    let buttonIcon: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            /// Header: gradient badge + title + accent tagline.
            ///
            /// **Rationale:** Establishes visual continuity between the landing cards and the detailed execution views.
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [accent, accent.opacity(0.55)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: icon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: 56, height: 56)
                .shadow(color: accent.opacity(0.35), radius: 7, y: 3)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.bold())
                    Text(tagline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(accent)
                }
                Spacer(minLength: 0)
            }

            Text(description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            /// The real domains this feature carries.
            ///
            /// **Rationale:** Re-affirming the scope with visual chips sets clear expectations about exactly what will be modified.
            FlowLayout(spacing: 8) {
                ForEach(SnapshotSectionKind.allCases, id: \.self) { DomainChip(kind: $0) }
            }

            button
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    @ViewBuilder private var button: some View {
        Button(action: action) {
            Label(buttonTitle, systemImage: buttonIcon)
                .labelStyle(.matched)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .appButton(.primary)
        .controlSize(.large)
        .tint(accent)
        .disabled(disabled)
    }
}

/// A neutral rounded pill for one snapshot domain (icon + short label) — shows
/// what the feature moves without adding another color to the card.
private struct DomainChip: View {
    let kind: SnapshotSectionKind

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.icon)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
            Text(kind.shortLabel)
                .font(.caption.weight(.medium))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.secondary.opacity(0.10)))
        .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 1))
    }
}

private extension SnapshotSectionKind {
    /// Compact label for the domain chips (the full `title` is too long to wrap nicely).
    var shortLabel: String {
        switch self {
        case .brew: return "Homebrew"
        case .python: return "Python"
        case .pip: return "pip"
        case .shell: return "Shell"
        case .shortcuts: return "Shortcuts"
        case .git: return "Git"
        case .projects: return "Projects"
        }
    }
}

/// Minimal wrapping layout so the domain chips flow onto as many rows as needed.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    /// Calculates the bounding layout dimensions for a dynamic flow container.
    /// - Parameters:
    ///   - proposal: The dimensional boundary requested by the parent container.
    ///   - subviews: The active rendering tree requiring layout resolution.
    ///   - cache: Extensible performance buffers holding intermediate pass geometry.
    /// - Returns: The fully calculated bounding box enclosing all flowed children.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    /// Executes the physical spatial positioning of child views within a flow layout.
    /// - Parameters:
    ///   - bounds: The explicit drawing coordinates enclosing the parent frame.
    ///   - proposal: The dimensional boundary requested by the parent container.
    ///   - subviews: The active rendering tree requiring layout resolution.
    ///   - cache: Extensible performance buffers holding intermediate pass geometry.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Working / scanning

private struct SnapshotWorkingView: View {
    let label: String
    var tint: Color = .blue

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48))
                .symbolEffect(.pulse, options: .repeating)
                .foregroundStyle(tint)

            Text(label.isEmpty ? "Working…" : label)
                .font(.title2.bold())

            ProgressView()
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Capture ready

private struct SnapshotCaptureReadyView: View {
    @ObservedObject var vm: SnapshotViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            SmoothPageScroll {
                VStack(spacing: 24) {
                    MasterHeaderView(
                        title: "Snapshot Ready",
                        subtitle: "Review what was captured, then export it to a portable file.",
                        image: "arrow.triangle.2.circlepath.circle.fill",
                        color: .green
                    )

                    ErrorBanner(message: $vm.errorMessage)

                    if let snap = vm.capturedSnapshot {
                        summaryCard(snap)
                        contentsCard(snap)
                        if !snap.warnings.isEmpty { warningsCard(snap) }
                    }

                    Color.clear.frame(height: 88)
                }
                .padding(.vertical)
            }

            exportBar
        }
    }

    /// Sticky export footer (same grammar as the restore/Cruft bar), green flow.
    ///
    /// **Rationale:** Anchoring primary calls to action to the bottom of the scroll view guarantees they are always accessible regardless of list length.
    private var exportBar: some View {
        let exported = vm.lastExportURL != nil
        return SnapshotFooterBar(
            title: exported ? "Snapshot exported" : "Ready to export",
            subtitle: exported
                ? "Saved to \(vm.lastExportURL?.lastPathComponent ?? "")"
                : "\(totalItems) items · nothing leaves your Mac until you pick a location"
        ) {
            /// `.neutral` (bordered) so this matches the adjacent Export button's
            /// height exactly — both native AppKit styles honour `.controlSize(.large)`,
            /// so they line up by construction rather than by a hand-tuned frame height.
            ///
            /// **Gotchas:** Attempting to force-match button heights with hardcoded frame modifiers breaks catastrophically when the user changes their system font size.
            Button { vm.discardCapture() } label: {
                Text("Discard").fontWeight(.semibold)
            }
            .appButton(.neutral)
            .controlSize(.large)
            .disabled(vm.isWorking)

            Button { Task { await vm.export() } } label: {
                Text(exported ? "Export Again…" : "Export…")
                    .fontWeight(.semibold)
                    .frame(minWidth: 140)
            }
            .appButton(.primary)
            .tint(.green)
            .controlSize(.large)
            .disabled(vm.isWorking)
        }
    }

    private var totalItems: Int {
        vm.capturedSnapshot?.inventory.reduce(0) { $0 + $1.count } ?? 0
    }

    /// Machine + stats header (mirrors the restore screen's source card).
    ///
    /// **Rationale:** Providing the source machine context reassures the user that they are restoring the correct archive.
    /// - Parameter snap: The top-level snapshot container bridging telemetry sources.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func summaryCard(_ snap: CatalystSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.title2)
                    .foregroundColor(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("This Mac").font(.headline)
                    Text("\(snap.source.userName) · \(snap.source.os) · \(snap.source.arch)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 20) {
                    StatBadge_Small(count: snap.inventory.count, label: "Categories", color: .green)
                    StatBadge_Small(count: totalItems, label: "Items", color: .green)
                    StatBadge_Small(count: snap.warnings.count, label: "Warnings",
                                    color: snap.warnings.isEmpty ? .secondary : .orange)
                }
            }
            SectionDivider()
            Text("Captured \(snap.createdAt.formatted(date: .abbreviated, time: .shortened)) · Catalyst \(snap.source.catalystVersion)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .cardStyle()
    }

    /// Per-category inventory.
    ///
    /// **Rationale:** Grouping operations by domain (Homebrew, Pip, Secrets) matches the mental model of the underlying package managers.
    /// - Parameter snap: The top-level snapshot container bridging telemetry sources.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func contentsCard(_ snap: CatalystSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("What's Inside").font(.headline)
                Spacer()
                Text("\(totalItems) items")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            SectionDivider()
            Text("Environment metadata and public config only — no passwords, tokens, SSH private keys, or .env files.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(snap.inventory.enumerated()), id: \.element.kind) { index, entry in
                    if index > 0 { SectionDivider() }
                    InventoryRow(kind: entry.kind, count: entry.count)
                }
            }
            .padding(.top, 4)
        }
        .cardStyle()
    }

    /// Highlights potential restoration conflicts identified within the snapshot payload.
    /// - Parameter snap: The top-level snapshot container bridging telemetry sources.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func warningsCard(_ snap: CatalystSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Heads Up").font(.headline)
            }
            SectionDivider()
            ForEach(Array(snap.warnings.enumerated()), id: \.offset) { _, warning in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5)).foregroundColor(.orange)
                        .padding(.top, 6)
                    Text(warning).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .cardStyle()
    }

}

/// Standardizes the visual presentation of a single recorded environment variable.
private struct InventoryRow: View {
    let kind: SnapshotSectionKind
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.icon)
                .foregroundColor(sectionColor(kind.color))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.body)
                Text(kind.captureBlurb).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
        }
        .padding(.vertical, 8)
    }
}

private extension SnapshotSectionKind {
    /// One-line description of what this category captures, shown in the inventory.
    var captureBlurb: String {
        switch self {
        case .brew: return "Taps, formulae & casks"
        case .python: return "Interpreters (brew, pyenv, system)"
        case .pip: return "Packages pinned per interpreter"
        case .shell: return "Full ~/.zshrc (scrubbed) + managed blocks"
        case .shortcuts: return "Installed SmartShortcuts"
        case .git: return "Name, email & aliases"
        case .projects: return "Tracked venv projects"
        }
    }
}

// MARK: - Restore plan

private struct SnapshotRestorePlanView: View {
    @ObservedObject var vm: SnapshotViewModel
    @ObservedObject private var installPrefs = InstallPreferences.shared
    @State private var expanded: Set<SnapshotSectionKind> = []

    private var isStatus: Bool { vm.isShowingStatus }
    private var hasPipActions: Bool { vm.actions.contains { $0.kind == .pip } }

    var body: some View {
        ZStack(alignment: .bottom) {
            SmoothPageScroll {
                VStack(spacing: 20) {
                    if let snap = vm.loadedSnapshot { sourceCard(snap) }

                    /// One-click bootstrap for a fresh Mac — shown only while choosing,
                    /// when something the snapshot needs is missing.
                    ///
                    /// **Gotchas:** Hiding this bootstrap card leaves users stranded on fresh macOS installs, forcing them to open Terminal and manually install Xcode tools.
                    if !isStatus && !vm.missingPrereqs.isEmpty { prerequisitesCard }

                    /// Install space picker — only when the plan actually restores pip
                    /// packages, and only while choosing (hidden during the run).
                    ///
                    /// **Rationale:** Dynamically exposing configuration only when required reduces cognitive load for users restoring simple dotfile-only snapshots.
                    if !isStatus && hasPipActions { installSpaceCard }

                    /// Passphrase prompt — only when this snapshot actually carries
                    /// sealed secrets. Optional by design: skipping it costs the user
                    /// that one row and nothing else.
                    ///
                    /// **Gotchas:** Forcing a hard requirement on the passphrase blocks the entire environment restore if the user simply forgot their password.
                    if !isStatus, let count = vm.sealedSecretCount {
                        SnapshotSecretsUnlockCard(
                            count: count,
                            passphrase: $vm.restorePassphrase,
                            validation: vm.secretsValidation,
                            disabled: vm.isWorking,
                            onValidate: { Task { await vm.validateRestorePassphrase() } }
                        )
                    }

                    if isStatus {
                        if let summary = vm.summary {
                            RestoreSummaryCard(summary: summary)
                            /// The secrets step is idempotent and independent of the
                            /// pipeline, so a skipped/mistyped passphrase is fixable
                            /// right here — no re-running the restore.
                            ///
                            /// **Rationale:** Designing for failure allows users to confidently retry cryptographic operations without fearing environment corruption.
                            if let count = vm.sealedSecretCount, vm.pendingSecretPlaceholders > 0 {
                                secretsRetryCard(count)
                            }
                        } else {
                            runningCard
                        }
                    }

                    contentsCard

                    if isStatus {
                        ConsoleOutputView(console: vm.console, title: "Restore Output")
                    }

                    Color.clear.frame(height: 96)
                }
                .padding(.vertical)
            }

            /// Footer appears only when there's a selection to act on — same as
            /// Cruft Sweeper's delete bar.
            ///
            /// **Gotchas:** Rendering an active "Restore" button when 0 items are selected creates ambiguous dead-clicks that confuse users.
            if isStatus {
                statusBar
            } else if vm.actionableCount > 0 {
                previewBar
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { vm.discardPlan() } label: {
                    Image(systemName: "xmark")
                }
                .help("Close snapshot")
                .disabled(vm.isWorking)
            }
        }
    }

    /// Live progress card shown on the Status screen while a run is in flight.
    /// Determinate: the bar tracks completed / total runnable actions so the user
    /// can see forward motion instead of an opaque spinner. (We deliberately don't
    /// show a time estimate — installs are network/wheel-bound and unpredictable;
    /// step count is the honest signal.)
    ///
    /// **Rationale:** Providing deterministic progress prevents users from forcibly terminating the app during a long Homebrew compilation phase.
    private var runningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(vm.workingLabel.isEmpty ? "Restoring…" : vm.workingLabel).font(.headline)
                Spacer()
                Text("\(vm.runDone) of \(vm.runTotal)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            if vm.runTotal > 0 {
                ProgressView(value: vm.progressFraction)
                    .tint(.blue)
            }
        }
        .cardStyle()
    }

    /// "Install All" bootstrap: lists what this Mac is missing for the snapshot
    /// (Command Line Tools, Homebrew, Python interpreters) and installs them in
    /// dependency order via the injected Dashboard installers — so a fresh Mac is
    /// resolved right here, no detour. Homebrew/Python complete inline; Command Line
    /// Tools hands off to Apple's dialog.
    ///
    /// **Gotchas:** Skipping the dependency ordering causes Python installations to fail immediately if Homebrew hasn't finished linking.
    private var prerequisitesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundColor(.orange)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Set Up Prerequisites").font(.subheadline.bold())
                    Text("This Mac is missing what some items need. Install it all here — no trip to the Dashboard.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                ForEach(vm.missingPrereqs) { prereq in
                    HStack(spacing: 10) {
                        Image(systemName: "circle.badge.exclamationmark.fill")
                            .foregroundColor(.orange).font(.caption)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(prereq.title).font(.body)
                            Text(prereq.detail).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text("missing").font(.caption2).foregroundColor(.orange)
                    }
                    .padding(.vertical, 8)
                    if prereq.id != vm.missingPrereqs.last?.id { SectionDivider() }
                }
            }

            Button { Task { await vm.installPrerequisites() } } label: {
                HStack(spacing: 8) {
                    if vm.isWorking { ProgressView().controlSize(.small) }
                    Text(vm.isWorking ? "Installing…" : "Install All (\(vm.missingPrereqs.count))")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .appButton(.primary)
            .tint(.blue)
            .controlSize(.large)
            .disabled(vm.isWorking)

            Text("Homebrew and Python install with your permission; Command Line Tools opens Apple's installer. Follow the Logs screen for detail.")
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    /// Install-space picker, shown at the top of Migrate when the plan restores pip
    /// packages. Binds the global `InstallPreferences.mode` (single source of truth):
    /// on Protected, externally-managed (3.12+) pip sets are skipped rather than
    /// force-overridden; User space / System-wide install them with the matching flag.
    ///
    /// **Rationale:** Surfacing the PEP-668 boundary explicitly in the UI educates the user on modern macOS Python constraints before they authorize a global restore.
    private var installSpaceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .foregroundColor(.blue)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Install Space").font(.subheadline.bold())
                    Text("Where pip packages install on externally-managed Python (3.12+).")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer(minLength: 12)
                Picker("", selection: $installPrefs.mode) {
                    ForEach(PipInstallMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(vm.isWorking)
            }
            Text(installPrefs.mode.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    /// Post-run retry for the secrets step alone. Appears only when the snapshot
    /// had secrets AND placeholders are still sitting in `~/.zshrc` — i.e. the
    /// passphrase was skipped or wrong. Applying is a single file rewrite, so it
    /// needs neither the plan nor another restore pass.
    /// - Parameter count: The total number of consecutive authorization failures.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func secretsRetryCard(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SnapshotSecretsUnlockCard(
                count: count,
                passphrase: $vm.restorePassphrase,
                validation: vm.secretsValidation,
                disabled: vm.isWorking,
                onValidate: { Task { await vm.validateRestorePassphrase() } }
            )
            HStack {
                if let result = vm.unlockResult {
                    Text(result).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button { Task { await vm.applySecretsNow() } } label: {
                    Text("Apply Secrets").fontWeight(.semibold)
                }
                .appButton(.primary)
                .tint(.purple)
                .controlSize(.large)
                .disabled(vm.isWorking || vm.secretsValidation == .checking)
            }
        }
    }

    /// Source + plan stats in one informative header card (4.11-style: lead with
    /// the actionable numbers, not celebration).
    ///
    /// **Rationale:** Professional tools prioritize data density over empty space; surfacing counts immediately helps users verify the snapshot integrity.

    /// - Parameter snap: The top-level snapshot container bridging telemetry sources.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func sourceCard(_ snap: CatalystSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill")
                    .font(.title2)
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Imported Snapshot")
                        .font(.headline)
                    Text("\(snap.source.userName) · \(snap.source.os) · \(snap.source.arch) · \(snap.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 20) {
                    StatBadge_Small(count: vm.actionableCount, label: "To Apply", color: .blue)
                    StatBadge_Small(count: vm.satisfiedCount, label: "Already Set", color: .green)
                    StatBadge_Small(count: vm.blockedCount, label: "Blocked", color: .orange)
                }
            }
        }
        .cardStyle()
    }

    /// Contents (grouped, collapsible — mirrors Cruft's "Detailed Results")
    ///
    /// **Rationale:** Collapsible sections allow users to drill into specific domains (like pip) without being overwhelmed by a 500-item flattened list.

    private var contentsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Snapshot Contents").font(.headline)
                Spacer()
                let anyCollapsed = vm.groupedActions.contains { !expanded.contains($0.kind) }
                Button(anyCollapsed ? "Expand All" : "Collapse All") {
                    if anyCollapsed { expanded = Set(vm.groupedActions.map { $0.kind }) }
                    else { expanded.removeAll() }
                }
                .appButton(.plain)
                .font(.caption.bold())
                .disabled(vm.isWorking)
            }
            SectionDivider()

            ForEach(Array(vm.groupedActions.enumerated()), id: \.element.kind) { index, group in
                sectionGroup(group.kind, items: group.items)
                if index < vm.groupedActions.count - 1 { SectionDivider().padding(.vertical, 2) }
            }
        }
        .cardStyle()
    }

    /// Groups related snapshot restoration steps under a common collapsible header.
    /// - Parameters:
    ///   - kind: The discrete module type matching the action array.
    ///   - items: The sequential tasks generated for system synchronization.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func sectionGroup(_ kind: SnapshotSectionKind, items: [RestoreAction]) -> some View {
        let readOnly = isStatus
        let selected = items.filter { $0.isActionable && $0.selected }.count
        let actionable = items.filter { $0.isActionable }.count
        return InstantDisclosureGroup(
            isExpanded: expandBinding(kind),
            label: {
                HStack(spacing: 12) {
                    Image(systemName: kind.icon)
                        .foregroundColor(sectionColor(kind.color))
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.title).font(.subheadline.bold())
                        Text(actionable == 0 ? "\(items.count) item(s) · all set" : "\(selected) of \(actionable) selected · \(items.count) total")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if actionable > 0 && !readOnly {
                        Button(selected == actionable ? "None" : "All") {
                            vm.setSection(kind, selected: selected != actionable)
                        }
                        .appButton(.plain)
                        .font(.caption.bold())
                        .foregroundColor(.blue)
                        .disabled(vm.isWorking)
                    }
                }
            },
            content: {
                LazyVStack(spacing: 0) {
                    SectionDivider().padding(.vertical, 8)
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, action in
                        ActionRow(
                            title: action.title,
                            detail: action.commandPreview,
                            status: action.status,
                            selected: action.selected,
                            satisfied: action.alreadySatisfied,
                            blockedReason: action.blockedReason,
                            message: action.message,
                            disabled: vm.isWorking,
                            readOnly: readOnly,
                            extraNote: skipNote(for: action),
                            willSkip: skipNote(for: action) != nil,
                            onToggle: { vm.setSelected(action.id, $0) }
                        )
                        .equatable()
                        if i < items.count - 1 { SectionDivider() }
                    }
                }
            }
        )
    }

    /// Sticky action bars (opaque, same chrome as Cruft's delete bar)
    ///
    /// **Gotchas:** Transparent sticky bars cause text collision when the user scrolls the main list underneath them, destroying legibility.

    /// Preview phase: choose items, then Dry run or Restore (→ Status screen).
    private var previewBar: some View {
        SnapshotFooterBar(
            title: "\(vm.actionableCount) items selected",
            subtitle: "Idempotent & resumable · already-set and blocked items are skipped"
        ) {
            Button { Task { await vm.runRestore() } } label: {
                Text("Restore \(vm.actionableCount)")
                    .fontWeight(.semibold)
                    .frame(minWidth: 140)
            }
            .appButton(.primary)
            .tint(.blue)
            .controlSize(.large)
            .disabled(vm.isWorking)
        }
    }

    /// Status phase: Cancel while running, else Back to Preview / Done.
    private var statusBar: some View {
        let title = vm.isWorking
            ? (vm.workingLabel.isEmpty ? "Working…" : vm.workingLabel)
            : "Restore finished"
        let subtitle = vm.isWorking ? "Running…" : "Review the results above"
        return SnapshotFooterBar(title: title, subtitle: subtitle) {
            if vm.isWorking {
                Button { vm.cancel() } label: {
                    Text("Cancel").fontWeight(.semibold)
                }
                .appButton(.neutral)
                .controlSize(.large)
            } else {
                Button { vm.backToPreview() } label: {
                    Text("Back to Preview").fontWeight(.semibold)
                }
                .appButton(.neutral)
                .controlSize(.large)

                Button { vm.discardPlan() } label: {
                    Text("Done")
                        .fontWeight(.semibold)
                        .frame(minWidth: 140)
                }
                .appButton(.primary)
                .tint(.blue)
                .controlSize(.large)
            }
        }
    }

    /// Helpers
    ///
    /// **Rationale:** Grouping internal view builders separates the declarative layout logic from the structural hierarchy above.

    /// Live note for a pip row reflecting the current Install Space: on Protected,
    /// externally-managed (3.12+) sets will be skipped on restore. Recomputes as the
    /// picker changes because this view observes `installPrefs`.
    /// - Parameter action: The targeted instruction executing the restoration step.
    /// - Returns: An optional string detailing bypass conditions, or nil.
    private func skipNote(for action: RestoreAction) -> String? {
        guard action.kind == .pip, installPrefs.mode == .protected,
              action.blockedReason == nil, !action.alreadySatisfied else { return nil }
        let mm = action.key.hasPrefix("pip.") ? String(action.key.dropFirst(4)) : ""
        guard VersionComparator.requiresBreakSystemPackages(pythonVersion: mm) else { return nil }
        return "Protected space — will skip on restore. Pick User space above to install."
    }

    /// Constructs a dynamic binding to track the expansion state of a specific section.
    /// - Parameter kind: The specific section block queried for expansion tracking.
    /// - Returns: An interactive boolean binding linked to view state.
    private func expandBinding(_ kind: SnapshotSectionKind) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(kind) },
            set: { if $0 { expanded.insert(kind) } else { expanded.remove(kind) } }
        )
    }
}

// MARK: - Action row (Equatable, plain values — CODING_STANDARDS 3.6)

private struct ActionRow: View, Equatable {
    let title: String
    let detail: String
    let status: RestoreStatus
    let selected: Bool
    let satisfied: Bool
    let blockedReason: String?
    let message: String?
    let disabled: Bool
    var readOnly: Bool = false
    /// A live, mode-dependent hint (e.g. "Protected space — will skip") that isn't
    /// part of the action model — recomputed as the Install Space picker changes.
    var extraNote: String? = nil
    /// When true (Protected space will skip this pip set), the toggle is replaced by
    /// a plain "will skip" label — toggling it wouldn't change the outcome.
    var willSkip: Bool = false
    let onToggle: (Bool) -> Void

    static func == (l: ActionRow, r: ActionRow) -> Bool {
        l.title == r.title && l.status == r.status && l.selected == r.selected
            && l.satisfied == r.satisfied && l.blockedReason == r.blockedReason
            && l.message == r.message && l.disabled == r.disabled && l.readOnly == r.readOnly
            && l.extraNote == r.extraNote && l.willSkip == r.willSkip
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leadingIndicator.frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                if let blockedReason {
                    Text(blockedReason).font(.caption).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let message {
                    Text(message).font(.caption2).foregroundColor(.secondary)
                }
                if let extraNote {
                    Text(extraNote).font(.caption2).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var trailing: some View {
        if satisfied {
            Text("already set").font(.caption2).foregroundColor(.green)
        } else if blockedReason != nil {
            Text("blocked").font(.caption2).foregroundColor(.orange)
        } else if readOnly {
            runStatusLabel
        } else if willSkip {
            Text("will skip").font(.caption2).foregroundColor(.orange)
        } else {
            Toggle("", isOn: Binding(get: { selected }, set: onToggle))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(disabled)
        }
    }

    /// On the Status screen the toggle is replaced by a word describing the run.
    @ViewBuilder private var runStatusLabel: some View {
        switch status {
        case .pending: Text(selected ? "queued" : "not selected").font(.caption2).foregroundColor(.secondary)
        case .running: Text("running…").font(.caption2).foregroundColor(.blue)
        case .succeeded: Text("done").font(.caption2).foregroundColor(.green)
        case .partial: Text("partial").font(.caption2).foregroundColor(.orange)
        case .failed: Text("failed").font(.caption2).foregroundColor(.red)
        case .skipped: Text("skipped").font(.caption2).foregroundColor(.secondary)
        }
    }

    /// Leading dot reflects the true state: satisfied/blocked take priority over
    /// the run status (those rows never execute).
    @ViewBuilder private var leadingIndicator: some View {
        if satisfied {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        } else if blockedReason != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.caption)
        } else {
            switch status {
            case .pending: Image(systemName: "circle").foregroundColor(.secondary.opacity(0.4)).font(.caption)
            case .running: ProgressView().controlSize(.small)
            case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .partial: Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
            case .skipped: Image(systemName: "minus.circle").foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Restore summary (status-header grammar 4.10, no false success 4.11)

private struct RestoreSummaryCard: View {
    let summary: RestoreSummary
    private var allClean: Bool { summary.isClean }

    private var title: String {
        allClean ? "Restore Complete" : "Restore Finished with Issues"
    }
    private var counts: String {
        var parts = ["\(summary.succeeded) applied"]
        if summary.partial > 0 { parts.append("\(summary.partial) partial") }
        parts.append("\(summary.failed) failed")
        parts.append("\(summary.skipped) skipped")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: allClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(allClean ? .green : .orange)
                .font(.title2)
            Text(title)
                .font(.headline)
            Text(counts)
                .font(.caption).foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
