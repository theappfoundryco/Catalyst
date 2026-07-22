import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class LoginItemsViewModel: ObservableObject {
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

    func scan() async {
        if report == nil { state = .scanning }
        logger.log("🚀 Scanning startup items…")
        let newReport = await service.scan()
        self.report = newReport
        self.state = .ready
        logger.log("🚀 Startup scan: \(newReport.loginItems.count) login item(s), \(newReport.agents.count) launch agent(s)")
    }

    func toggleAgent(_ agent: LaunchAgentItem) async {
        busyItemID = agent.id
        defer { busyItemID = nil }
        let ok = await service.setAgentEnabled(agent, enabled: !agent.isLoaded)
        logger.log(ok ? "🚀 \(agent.isLoaded ? "Unloaded" : "Loaded") \(agent.label)" : "❌ Failed to toggle \(agent.label)")
        await scan()
    }

    func removeAgent(_ agent: LaunchAgentItem) async {
        busyItemID = agent.id
        defer { busyItemID = nil }
        let ok = await service.removeAgent(agent)
        logger.log(ok ? "🗑️ Removed agent \(agent.label)" : "❌ Failed to remove \(agent.label)")
        await scan()
    }

    func removeLoginItem(_ item: LoginItem) async {
        busyItemID = item.id
        defer { busyItemID = nil }
        let ok = await service.removeLoginItem(item)
        logger.log(ok ? "🗑️ Removed login item \(item.name)" : "❌ Failed to remove login item \(item.name)")
        await scan()
    }

    func reveal(path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
