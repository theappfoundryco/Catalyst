//
//  AppInfoCenter.swift
//  Catalyst
//
//  A modular info system: an `InfoDot` (ⓘ) can be dropped anywhere with a topic.
//  Clicking it shows a quick popover; "Learn more" opens ONE shared, topic-
//  switched sheet (`AppInfoSheet`) attached at the app root. All explainer copy
//  lives here as the single source of truth.
//

import SwiftUI
import Combine

/// A documentation topic surfaced by `InfoDot` and the shared info sheet.
enum InfoTopic: String, CaseIterable, Identifiable {
    case installModes
    case pep668
    case risks
    case reverting

    var id: String { rawValue }

    /// Short label for the sheet's segmented switcher.
    var tabTitle: String {
        switch self {
        case .installModes: return "Install modes"
        case .pep668: return "PEP 668"
        case .risks: return "Risks"
        case .reverting: return "Reverting"
        }
    }

    var heading: String {
        switch self {
        case .installModes: return "Install modes"
        case .pep668: return "Externally-managed environments (PEP 668)"
        case .risks: return "What can go wrong"
        case .reverting: return "Turning it off"
        }
    }

    /// Two-line summary shown in the quick popover.
    var summary: String {
        switch self {
        case .installModes:
            return "Choose where pip installs on Python 3.12+: Protected (safe default), User space, or System-wide."
        case .pep668:
            return "Python 3.12+ marks its environment 'externally managed', so pip won't modify it unless you override."
        case .risks:
            return "Overriding can overwrite packages Homebrew or macOS manage, and break other tools."
        case .reverting:
            return "Set Install mode back to Protected any time — it applies immediately, everywhere."
        }
    }

    /// Full explanation shown in the shared sheet.
    var body: String {
        switch self {
        case .installModes:
            return """
            On Python 3.12+, Catalyst offers three install modes (global, applied everywhere):

            • Protected — the default. No override flag is added. Installs into the system Python may be refused; nothing risky happens.

            • User space — adds --break-system-packages --user, so packages land in your personal user site instead of the system directory. Safer, but Homebrew's Python disables the user site, so this can be rejected.

            • System-wide — adds --break-system-packages, writing directly into the OS-managed Python. Highest reach, highest risk.

            Virtual environments are never affected — they aren't externally managed, so no flag is used there.
            """
        case .pep668:
            return """
            PEP 668 lets a Python distribution mark itself "externally managed" (via an EXTERNALLY-MANAGED marker). Homebrew and recent system Pythons (3.12+) do this.

            When an interpreter is externally managed, pip refuses to install or upgrade into it by default — to protect packages that the OS or Homebrew own. That's why some upgrades appear "held back": pip is intentionally declining to write.

            PEP 668 only blocks writes. It does not hide anything from the outdated list — Catalyst still shows what's upgradable; the mode only decides whether the upgrade is allowed to proceed.
            """
        case .risks:
            return """
            Overriding the protection can:

            • Overwrite or downgrade packages that Homebrew installed, leaving `brew` and Python out of sync.
            • Break system tools that depend on specific versions in the managed Python.
            • Create hard-to-diagnose conflicts that a `brew reinstall python` may be needed to repair.

            If you only need packages for your own projects, prefer a virtual environment or User space over System-wide.
            """
        case .reverting:
            return """
            The install mode is a single global setting. Switch it back to Protected from any Python selector and it takes effect immediately for every subsequent install — there's nothing to undo per-package.

            Packages already installed under an override stay installed. To remove them, upgrade/uninstall them explicitly, or (for Homebrew's Python) `brew reinstall python@<version>` to restore the managed set.
            """
        }
    }
}

/// App-wide coordinator for the shared info sheet. Any `InfoDot` calls
/// `present(_:)`; the root view presents `AppInfoSheet` bound to `topic`.
@MainActor
final class InfoCenter: ObservableObject {
    static let shared = InfoCenter()
    @Published var topic: InfoTopic?
    private init() {}
    func present(_ topic: InfoTopic) { self.topic = topic }
}

/// A small ⓘ button. Tap → quick popover summary; "Learn more" → shared sheet.
struct InfoDot: View {
    let topic: InfoTopic
    @State private var showPopover = false

    var body: some View {
        Button { showPopover = true } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("More info")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(topic.heading)
                    .font(.subheadline.weight(.semibold))
                Text(topic.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Learn more →") {
                    showPopover = false
                    InfoCenter.shared.present(topic)
                }
                .font(.caption)
                .buttonStyle(.link)
            }
            .padding(12)
            .frame(width: 260)
        }
    }
}

/// The single shared info sheet with a segmented topic switcher, deep-linked to
/// whichever topic opened it.
struct AppInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: InfoTopic

    init(initialTopic: InfoTopic) {
        _selected = State(initialValue: initialTopic)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("About Package Installation")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Picker("", selection: $selected) {
                ForEach(InfoTopic.allCases) { topic in
                    Text(topic.tabTitle).tag(topic)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(selected.heading)
                        .font(.title3.weight(.semibold))
                    Text(selected.body)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(20)
        .frame(width: 460, height: 400)
    }
}
