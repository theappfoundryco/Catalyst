import Foundation
import SwiftUI
import AppKit
import Combine

/// A view model that coordinates macOS Login Items and Launch Agents.
///
/// It uses `LoginItemsService` to scan for startup processes and allows users to remove
/// stale items or toggle LaunchAgents via `launchctl`.
///
/// ```swift
/// @StateObject var vm = LoginItemsViewModel()
/// await vm.scan()
/// ```
@MainActor
final class LoginItemsViewModel: ObservableObject {
    /// Encapsulates the asynchronous loading progression of system background daemons.
    enum State: Equatable {
        case idle
        case scanning
        case ready
    }

    @Published var state: State = .idle
    @Published var report: LoginItemsReport?
    @Published var busyItemID: String?

    private let service = LoginItemsService.shared
    private let logger = Logger.shared

    /// Scans the system for configured Login Items and Launch Agents.
    ///
    /// **Flow:**
    /// 1. Toggles ``state`` to `.scanning`.
    /// 2. Awaits ``LoginItemsService/scan()``.
    /// 3. Emits the resulting ``LoginItemsReport`` back to the UI thread.
    func scan() async {
        if report == nil { state = .scanning }
        logger.log("🚀 Scanning startup items…")
        let newReport = await service.scan()
        self.report = newReport
        self.state = .ready
        logger.log("🚀 Startup scan: \(newReport.loginItems.count) login item(s), \(newReport.agents.count) launch agent(s)")
    }

    /// Invokes `launchctl load` or `unload` for a given agent to toggle its enabled state.
    ///
    /// **Caveats:**
    /// - Locks the specific UI row using ``busyItemID`` during the shell invocation.
    ///
    /// - Parameter agent: The target ``LaunchAgentItem``.
    func toggleAgent(_ agent: LaunchAgentItem) async {
        busyItemID = agent.id
        defer { busyItemID = nil }
        let ok = await service.setAgentEnabled(agent, enabled: !agent.isLoaded)
        logger.log(ok ? "🚀 \(agent.isLoaded ? "Unloaded" : "Loaded") \(agent.label)" : "❌ Failed to toggle \(agent.label)")
        await scan()
    }

    /// Unloads and deletes a `.plist` LaunchAgent from the filesystem.
    ///
    /// **Caveats:**
    /// - This is a destructive operation; the plist is permanently removed from `~/Library/LaunchAgents/`.
    ///
    /// - Parameter agent: The target ``LaunchAgentItem``.
    func removeAgent(_ agent: LaunchAgentItem) async {
        busyItemID = agent.id
        defer { busyItemID = nil }
        let ok = await service.removeAgent(agent)
        logger.log(ok ? "🗑️ Removed agent \(agent.label)" : "❌ Failed to remove \(agent.label)")
        await scan()
    }

    /// Removes a standard GUI Login Item.
    ///
    /// **Rationale:**
    /// Because macOS deprecated the old direct APIs, this delegates to AppleScript internally
    /// to instruct System Events to delete the item from the user's GUI list.
    ///
    /// - Parameter item: The target ``LoginItem``.
    func removeLoginItem(_ item: LoginItem) async {
        busyItemID = item.id
        defer { busyItemID = nil }
        let ok = await service.removeLoginItem(item)
        logger.log(ok ? "🗑️ Removed login item \(item.name)" : "❌ Failed to remove login item \(item.name)")
        await scan()
    }

    /// Opens Finder with the specified path selected.
    ///
    /// - Parameter path: The absolute file path to reveal.
    func reveal(path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
