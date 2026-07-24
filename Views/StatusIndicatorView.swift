import SwiftUI
import Combine

/// Status indicator bar shown at the bottom of the sidebar
///
/// ```swift
/// StatusIndicatorView(networkMonitor: networkMonitor)
/// ```
struct StatusIndicatorView: View {
    @ObservedObject var networkMonitor: NetworkMonitor
    @ObservedObject private var installPrefs = InstallPreferences.shared
    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            HStack(spacing: 8) {
                // Status dot
                Circle()
                    .fill(networkMonitor.status.color)
                    .frame(width: 8, height: 8)

                Text(networkMonitor.status.label)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                // Integrity/install-mode shield: green = Protected, red = an override.
                Image(systemName: installPrefs.isOverrideActive
                      ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundColor(installPrefs.isOverrideActive ? .red : .green)

                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
        .appButton(.plain)
        .help(networkMonitor.status.tooltip)
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            StatusPopoverView(networkMonitor: networkMonitor)
        }
    }
}

/// Expanded status popover with detailed system information
///
/// ```swift
/// StatusPopoverView(networkMonitor: networkMonitor)
/// ```
struct StatusPopoverView: View {
    @ObservedObject var networkMonitor: NetworkMonitor
    @ObservedObject private var installPrefs = InstallPreferences.shared
    @State private var isRefreshing = false
    @State private var pendingMode: PipInstallMode = .protected
    @State private var showModeConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Status")
                .font(.headline)
            
            SectionDivider()
            
            // Network
            StatusRow(
                icon: "network",
                label: "Network",
                status: networkMonitor.status.label,
                color: networkMonitor.status.color
            )
            
            // Homebrew
            StatusRow(
                icon: "mug.fill",
                label: "Homebrew",
                status: networkMonitor.isBrewInstalled ? "Installed" : "Not Installed",
                color: networkMonitor.isBrewInstalled ? .green : .red
            )
            
            // Python
            StatusRow(
                icon: "terminal.fill",
                label: "Python",
                status: "\(networkMonitor.pythonVersionCount) version\(networkMonitor.pythonVersionCount == 1 ? "" : "s")",
                color: networkMonitor.pythonVersionCount > 0 ? .green : .secondary
            )
            
            // Background Tasks
            if let task = networkMonitor.activeBackgroundTask {
                StatusRow(
                    icon: "arrow.triangle.2.circlepath",
                    label: "Background",
                    status: task,
                    color: .blue,
                    isAnimating: true
                )
            } else {
                StatusRow(
                    icon: "checkmark.circle",
                    label: "Background",
                    status: "No active tasks",
                    color: .secondary
                )
            }
            
            SectionDivider()

            // App-wide install mode (PEP 668 override). Switching away from Protected
            // requires explicit consent; reverting to Protected is immediate (CODING_STANDARDS 2.7).
            installModeSection

            SectionDivider()

            // Refresh button — sized to match the dashboard "Install" button
            // (regular control size, default font).
            Button {
                Task {
                    isRefreshing = true
                    // Deliberate 2.5s delay before the actual refresh.
                    try? await Task.sleep(for: .seconds(2.5))
                    await networkMonitor.forceCheck()
                    isRefreshing = false
                }
            } label: {
                if isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                        .labelStyle(.matched)
                }
            }
            .appButton(.neutral)
            .disabled(isRefreshing)
        }
        .padding()
        .frame(width: 250)
        .confirmationDialog("Override system integrity?",
                            isPresented: $showModeConfirm, titleVisibility: .visible) {
            Button("Enable \(pendingMode.title)", role: .destructive) {
                installPrefs.mode = pendingMode
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingMode.confirmMessage)
        }
    }

    /// App-wide install-mode selector (PEP 668). A green/red shield mirrors the sidebar
    /// indicator; the menu changes the mode with consent for overrides.
    private var installModeSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundColor(installPrefs.isOverrideActive ? .red : .green)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text("Install Mode")
                    .font(.subheadline)
                Text(installPrefs.mode.menuSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Menu {
                ForEach(PipInstallMode.allCases) { mode in
                    Button { selectMode(mode) } label: {
                        if mode == installPrefs.mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// Apply a mode: Protected is immediate; any override asks for confirmation first.
    /// - Parameter mode: The target operational state representing the user selection.
    private func selectMode(_ mode: PipInstallMode) {
        if mode == .protected {
            installPrefs.mode = .protected
        } else if mode != installPrefs.mode {
            pendingMode = mode
            showModeConfirm = true
        }
    }
}

/// Individual status row in the popover
///
/// ```swift
/// StatusRow(icon: "network", label: "Network", status: "Online", color: .green)
/// ```
struct StatusRow: View {
    let icon: String
    let label: String
    let status: String
    let color: Color
    var isAnimating: Bool = false
    
    @State private var rotation: Double = 0
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 16)
                .rotationEffect(.degrees(rotation))
                .animation(
                    isAnimating
                        ? .linear(duration: 1).repeatForever(autoreverses: false)
                        : .default,
                    value: rotation
                )
            
            Text(label)
                .font(.subheadline)
            
            Spacer()
            
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            if isAnimating {
                rotation = 360
            }
        }
    }
}

// MARK: - User Profile (sidebar row + edit sheet)

/// Persisted local user profile: a display name and a chosen avatar.
///
/// This is the groundwork for the profile/identity area that the paid-era app
/// used for licence and invoice details; future releases hang more sections off
/// the same store and sheet. Today it holds exactly two fields, both local-only:
/// nothing here is ever sent anywhere (the app has no server — see
/// CODING_STANDARDS 12.1: never log or transmit user-identifying data).
///
/// ## Persistence
/// Backed by `UserDefaults` (same pattern as ``InstallPreferences``). `avatarID`
/// is the asset-catalog imageset name (`bottts-neutral-1`…`-100`); `nil` means
/// "no avatar chosen yet" and renders the neutral system-symbol placeholder —
/// deliberately NOT a random or hardcoded pick, so first launch never implies a
/// choice the user didn't make.
///
/// ## Validation
/// ``validationError(for:)`` is the single source of truth for name rules:
/// 1–30 characters, must start with a letter or digit, then letters, digits,
/// spaces, `.` `_` `'` `-`. Unicode letters/digits are allowed (`\p{L}\p{N}`),
/// so "Zoë" or "李明" are valid names.
///
/// - Important: `@MainActor` and observed by the sidebar row — mutations happen
///   only on Save from the sheet, so there is no high-frequency publishing to
///   jank the sidebar (CODING_STANDARDS 3.7).
///
/// ```swift
/// @ObservedObject var profile = UserProfileStore.shared
/// Text(profile.name)   // "Developer" until the user changes it
/// ```
@MainActor
final class UserProfileStore: ObservableObject {
    /// Shared singleton, mirroring ``InstallPreferences`` — profile is global app state.
    static let shared = UserProfileStore()

    /// Maximum allowed display-name length (characters, post-trim).
    static let nameLimit = 30
    /// Name shown before the user ever edits the profile.
    static let defaultName = "Developer"
    /// Every selectable avatar imageset name, in gallery order.
    ///
    /// The DiceBear "bottts-neutral" set lives in `Assets.xcassets/Avatars` as
    /// 100 individual imagesets, so this is derivable — but kept explicit so the
    /// picker never shows a broken image if the catalog and code drift.
    static let avatarIDs: [String] = (1...100).map { "bottts-neutral-\($0)" }

    private static let nameKey = "userProfileName"
    private static let avatarKey = "userProfileAvatarID"

    /// The display name shown in the sidebar row. Persisted on every change.
    @Published var name: String {
        didSet { UserDefaults.standard.set(name, forKey: Self.nameKey) }
    }

    /// The chosen avatar's imageset name, or `nil` for the neutral placeholder.
    @Published var avatarID: String? {
        didSet { UserDefaults.standard.set(avatarID, forKey: Self.avatarKey) }
    }

    private init() {
        let storedName = UserDefaults.standard.string(forKey: Self.nameKey)
        /// Re-validate on load: if a future rule change invalidates a stored
        /// name, fall back to the default instead of rendering a value the
        /// sheet would refuse to save.
        if let storedName, Self.validationError(for: storedName) == nil {
            name = storedName
        } else {
            name = Self.defaultName
        }
        let storedAvatar = UserDefaults.standard.string(forKey: Self.avatarKey)
        avatarID = storedAvatar.flatMap { Self.avatarIDs.contains($0) ? $0 : nil }
    }

    /// Cached validation regex (R4: never rebuild per keystroke in `body`).
    /// Anchored via `wholeMatch`; length is enforced by the quantifier so the
    /// regex alone is sufficient, but ``validationError(for:)`` still reports
    /// over-length separately for a friendlier message.
    private static let nameRegex = /[\p{L}\p{N}][\p{L}\p{N} ._'’-]{0,29}/

    /// Validates a candidate display name.
    ///
    /// - Parameter candidate: The raw text-field content (trimmed internally).
    /// - Returns: A user-facing error message, or `nil` when the name is valid.
    static func validationError(for candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return "Name can't be empty."
        }
        if trimmed.count > nameLimit {
            return "Name is limited to \(nameLimit) characters."
        }
        if trimmed.wholeMatch(of: nameRegex) == nil {
            return "Use letters, numbers, spaces, and . _ ' - (must start with a letter or number)."
        }
        return nil
    }
}

/// The avatar thumbnail: the chosen DiceBear image, or the neutral placeholder.
///
/// Square with a **continuous** rounded-rect clip — never a circle. The radius
/// is `size * 0.25`, i.e. the same corner-to-edge ratio as ``CardSize/standard``
/// cards scaled to avatar dimensions (12pt on a ~48pt-padded card ≈ a quarter of
/// the content module), and close to the macOS app-icon squircle ratio, so the
/// shape reads as "one of our cards", just smaller. `style: .continuous` is what
/// delivers the smooth Apple-style corner easing.
///
/// The placeholder (``UserProfileStore/avatarID`` == `nil`) is the
/// `person.crop.square.fill` system symbol on a subtle secondary fill: neutral,
/// theme-correct, and clearly "not yet chosen" — per the deliberate decision to
/// never show a random or hardcoded avatar the user didn't pick.
///
/// - Note: Asset-catalog images decode lazily and are cached by AppKit, so this
///   view is safe in the always-visible sidebar (no I/O in `body`).
struct UserAvatarView: View, Equatable {
    /// Imageset name from ``UserProfileStore/avatarIDs``, or `nil` for the placeholder.
    let avatarID: String?
    /// Edge length in points (the view is always square).
    let size: CGFloat

    /// Continuous-corner clip shape shared by avatar and placeholder.
    private var clip: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
    }

    var body: some View {
        Group {
            if let avatarID {
                Image(avatarID)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                clip
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(
                        Image(systemName: "person.crop.square.fill")
                            .font(.system(size: size * 0.5))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(clip)
    }
}

/// Sidebar footer row showing the local user profile; sits directly below
/// ``StatusIndicatorView`` (the "Connected" row). Clicking opens ``UserProfileSheet``.
///
/// Matches the status row's visual language: same horizontal padding, same 8pt
/// rounded `controlBackgroundColor` fill. Hover feedback is a cheap opacity
/// change with a short ease (CODING_STANDARDS 3.4 — no scale/spring on hover).
///
/// ```swift
/// UserProfileRow()
///     .padding(.horizontal, 8)
/// ```
struct UserProfileRow: View {
    /// The live profile — the row re-renders only when Save commits a change.
    @ObservedObject private var profile = UserProfileStore.shared
    /// Drives the `.sheet` presenting ``UserProfileSheet``.
    @State private var showingSheet = false
    /// Hover state for the cheap opacity/pencil affordance (no scale/spring, 3.4).
    @State private var isHovering = false

    var body: some View {
        Button {
            showingSheet = true
        } label: {
            HStack(spacing: 10) {
                UserAvatarView(avatarID: profile.avatarID, size: 32)

                Text(profile.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .opacity(isHovering ? 1 : 0)
            }
            /// Leading is tighter than the status row's 12pt: the avatar is a
            /// large block, so at equal insets its edge reads as sitting further
            /// right than the status row's small green dot. 8pt optically lines
            /// the avatar's left edge up with the dot above it.
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .opacity(isHovering ? 1.0 : 0.85)
            )
            .animation(.easeInOut(duration: 0.12), value: isHovering)
        }
        .appButton(.plain)
        .onHover { isHovering = $0 }
        .help("Edit your name and avatar")
        .sheet(isPresented: $showingSheet) {
            UserProfileSheet(isPresented: $showingSheet)
        }
    }
}

/// Sheet for editing the local user profile (name + avatar).
///
/// Layout is deliberately parallel to ``VirtualEnvCreationSheet``: fixed-size
/// `VStack(spacing: 0)` of header → ``SectionDivider`` → single scrolling
/// content column → ``SectionDivider`` → Cancel/Save footer, header and footer
/// on `controlBackgroundColor`.
///
/// Edits are staged in local `@State` and committed to ``UserProfileStore`` only
/// on Save, so Cancel (or closing the sheet) never leaves half-applied state and
/// the sidebar row never re-renders per keystroke (CODING_STANDARDS 3.7).
///
/// The avatar gallery is a `LazyVGrid` inside the sheet's ONE vertical scroll —
/// no nested vertical `ScrollView` (CODING_STANDARDS 3.2), and each tile is a
/// small `Equatable` leaf taking plain values + a closure (3.6), so hover/scroll
/// over 100 tiles stays smooth.
///
/// - Note: Future releases re-add the paid-era identity details (licence,
///   invoices, …) as further sections in this sheet; keep new sections in the
///   same single scroll column.
struct UserProfileSheet: View {
    @Binding var isPresented: Bool

    /// The committed profile; read on appear to seed the staged edits, written on Save.
    @ObservedObject private var profile = UserProfileStore.shared
    /// Staged name edit — committed on Save only, so Cancel discards cleanly.
    @State private var editedName = ""
    /// Staged avatar choice (`nil` = neutral placeholder) — committed on Save only.
    @State private var editedAvatarID: String?

    /// Computed once per keystroke against the cached regex — cheap enough for
    /// live feedback (R4 covers the formatter/regex caching).
    private var nameError: String? { UserProfileStore.validationError(for: editedName) }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            SectionDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameSection
                    avatarSection
                }
                .padding()
            }
            .scrollBounceBehavior(.basedOnSize) // ANTI_PATTERNS.md Rule 1

            SectionDivider()
            footerView
        }
        .frame(width: 500, height: 560)
        .onAppear {
            editedName = profile.name
            editedAvatarID = profile.avatarID
        }
    }

    // MARK: - Subviews

    /// Title + subtitle with a live avatar preview, on `controlBackgroundColor`
    /// (mirrors ``VirtualEnvCreationSheet``'s header).
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("User Profile")
                    .font(.headline)
                Text("Personalize your copy of Catalyst")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            UserAvatarView(avatarID: editedAvatarID, size: 40)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Name field with live validation feedback and an `n/30` character counter.
    /// The `onChange` hard-caps length so the field can never exceed
    /// ``UserProfileStore/nameLimit``; content rules surface via the orange label.
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display Name")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(UserProfileStore.defaultName, text: $editedName)
                .textFieldStyle(.roundedBorder)
                .onChange(of: editedName) { newValue in
                    /// Hard cap at the limit so the field can't run away past
                    /// validation; trimming happens on Save.
                    if newValue.count > UserProfileStore.nameLimit {
                        editedName = String(newValue.prefix(UserProfileStore.nameLimit))
                    }
                }

            HStack {
                if let nameError, !editedName.isEmpty {
                    Label(nameError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .transition(.opacity)
                }
                Spacer()
                Text("\(editedName.count)/\(UserProfileStore.nameLimit)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The avatar gallery: a lazy adaptive grid of ``AvatarTile``s inside the
    /// sheet's single scroll (no nested vertical `ScrollView` — 3.2). The
    /// "no avatar" tile leads so the placeholder is always one click away.
    private var avatarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Avatar")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 10)], spacing: 10) {
                /// The "no avatar" tile first: an explicit way back to the
                /// neutral placeholder, so choosing an avatar is reversible.
                AvatarTile(avatarID: nil, isSelected: editedAvatarID == nil) {
                    editedAvatarID = nil
                }
                ForEach(UserProfileStore.avatarIDs, id: \.self) { id in
                    AvatarTile(avatarID: id, isSelected: editedAvatarID == id) {
                        editedAvatarID = id
                    }
                }
            }
        }
    }

    /// Cancel/Save footer on `controlBackgroundColor` (mirrors
    /// ``VirtualEnvCreationSheet``). Save trims, commits both staged fields to
    /// ``UserProfileStore``, and dismisses; it stays disabled while the name is
    /// invalid so the store can never hold a value ``UserProfileStore/validationError(for:)`` rejects.
    private var footerView: some View {
        HStack {
            Button("Cancel") {
                isPresented = false
            }

            Spacer()

            Button("Save") {
                profile.name = editedName.trimmingCharacters(in: .whitespaces)
                profile.avatarID = editedAvatarID
                isPresented = false
            }
            .appButton(.primary)
            .keyboardShortcut(.defaultAction)
            .disabled(nameError != nil)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// One selectable tile in the avatar gallery.
///
/// Equatable leaf over plain values + a closure (CODING_STANDARDS 3.6): with
/// 101 tiles in the grid, only the tiles whose `isSelected` flips re-render on
/// a pick, not the whole gallery.
struct AvatarTile: View, Equatable {
    /// Imageset name, or `nil` for the neutral-placeholder tile.
    let avatarID: String?
    /// Whether this tile is the staged selection.
    let isSelected: Bool
    /// Called when the tile is clicked.
    let onSelect: () -> Void

    /// R1-row: closures are excluded from equality on purpose.
    static func == (lhs: AvatarTile, rhs: AvatarTile) -> Bool {
        lhs.avatarID == rhs.avatarID && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        Button(action: onSelect) {
            UserAvatarView(avatarID: avatarID, size: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.15),
                                      lineWidth: isSelected ? 2 : 1)
                )
        }
        .appButton(.plain)
        .help(avatarID == nil ? "No avatar (default placeholder)" : "")
    }
}

#Preview {
    StatusIndicatorView(networkMonitor: NetworkMonitor())
        .frame(width: 200)
        .padding()
}

#Preview("User profile row") {
    UserProfileRow()
        .frame(width: 235)
        .padding()
}
