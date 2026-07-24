import SwiftUI
import AppKit

/// The panel shown from the menu-bar icon: a compact health summary plus quick
/// actions, so the user can check status without opening the main window.
///
/// ```swift
/// MenuBarContentView(appVM: appViewModel)
/// ```
struct MenuBarContentView: View {
    @ObservedObject var appVM: AppViewModel
    @ObservedObject var dr: DrCatalystViewModel
    @ObservedObject var brew: OutdatedBrewViewModel

    init(appVM: AppViewModel) {
        self.appVM = appVM
        self.dr = appVM.drCatalystViewModel
        self.brew = appVM.outdatedBrewViewModel
    }

    private var scoreColor: Color {
        switch dr.currentScore {
        case 90...100: return .green
        case 70..<90: return .orange
        default: return .red
        }
    }

    private var scoreLabel: String {
        switch dr.currentScore {
        case 90...100: return "Excellent"
        case 70..<90: return "Fair"
        default: return "Needs Attention"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            /// Header
            ///
            /// **Rationale:** Visually anchors the condensed menubar popover with familiar branding.
            HStack(spacing: 8) {
                Image(systemName: "bolt.heart.fill")
                    .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("Catalyst").font(.headline)
                Spacer()
                if dr.isScanning {
                    ProgressView().controlSize(.small)
                }
            }

            Divider()

            /// Health score
            ///
            /// **Rationale:** Provides the primary at-a-glance metric for the entire system without opening the dashboard.
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(scoreColor.opacity(0.15), lineWidth: 6).frame(width: 52, height: 52)
                    Circle()
                        .trim(from: 0, to: CGFloat(min(max(dr.currentScore, 0), 100)) / 100)
                        .stroke(scoreColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 52, height: 52)
                    Text("\(dr.currentScore)").font(.system(.headline, design: .rounded)).fontWeight(.bold)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Health Score").font(.caption).foregroundColor(.secondary)
                    Text(scoreLabel).font(.subheadline).fontWeight(.semibold).foregroundColor(scoreColor)
                }
                Spacer()
            }

            /// Counts
            ///
            /// **Rationale:** Groups secondary metrics for users interested in payload size rather than pure health state.
            HStack(spacing: 8) {
                statChip(count: dr.criticalCount, label: "Critical", color: .red)
                statChip(count: dr.warningCount, label: "Warnings", color: .orange)
                statChip(count: brew.outdatedPackages.count, label: "Outdated", color: .blue)
            }

            Divider()

            /// Quick actions
            ///
            /// **Rationale:** Exposes immediate remediation paths directly from the menubar to reduce friction.
            VStack(spacing: 6) {
                actionButton("Open Catalyst", systemImage: "macwindow") { openMainWindow() }
                actionButton("Run Health Scan", systemImage: "stethoscope") {
                    openTab(.drCatalyst)
                    Task { await dr.scan() }
                }
                actionButton("Check Updates", systemImage: "arrow.triangle.2.circlepath") {
                    openTab(.brewUpdates)
                    Task { await brew.reset() }
                }
            }

            Divider()

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit Catalyst")
                    Spacer()
                }
            }
            .appButton(.plain)
            .font(.subheadline)
        }
        .padding(16)
        .frame(width: 280)
    }

    // MARK: - Pieces

    /// - Parameters:
    ///   - count: The numeric metric requiring highlighting.
    ///   - label: A brief descriptive noun for the count.
    ///   - color: The assigned semantic color reflecting priority.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func statChip(count: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)").font(.system(.title3, design: .rounded)).fontWeight(.bold).foregroundColor(color)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }

    /// A standardized clickable row for the Catalyst menu bar dropdown.
    /// - Parameters:
    ///   - title: The explicit user action label.
    ///   - systemImage: The associated SF Symbol glyph.
    ///   - action: The executable closure bound to tap events.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage).frame(width: 18)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .appButton(.plain)
        .font(.subheadline)
    }

    // MARK: - Actions

    /// - Parameter screen: The targeted primary navigation endpoint.
    private func openTab(_ screen: AppViewModel.Screen) {
        appVM.currentScreen = screen
        openMainWindow()
    }

    /// Brings the app (and its main window) to the front.
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}
