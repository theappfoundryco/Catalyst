import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LogsViewModel: ObservableObject {
    enum ExportType: String, CaseIterable {
        case terminal = "Terminal"
        case system = "System"
        case both = "Both"
    }
    
    @Published var terminalLogs: String = ""
    @Published var debugLogs: String = ""
    @Published var terminalAutoScroll = true
    @Published var debugAutoScroll = true
    @Published var selectedTab = 0 // 0 = Terminal, 1 = Debug
    @Published var exportType: ExportType = .both
    
    private var terminalCancellable: AnyCancellable?
    private var debugCancellable: AnyCancellable?
    private let logger: Logger

    // Coalesce streaming appends: a burst of lines becomes one @Published
    // mutation per ~120ms instead of one per line, so the log view re-lays-out
    // a handful of times per second, not once per chunk (R2).
    private var pendingTerminal = ""
    private var pendingDebug = ""
    private var flushTask: Task<Void, Never>?

    // Limit to ~500KB to prevent memory growth
    private let maxLogLength = 500_000

    init(logger: Logger) {
        self.logger = logger
    }
    
    func startup() {
        // Load existing logs
        self.terminalLogs = logger.getTerminalLogs()
        self.debugLogs = logger.getDebugLogs()
        
        // Start subscriptions immediately
        subscribeToLogs()
    }
    
    private func subscribeToLogs() {
        terminalCancellable = logger.terminalPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] line in
                guard let self = self else { return }
                self.pendingTerminal += line
                self.scheduleFlush()
            }

        debugCancellable = logger.debugPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] line in
                guard let self = self else { return }
                self.pendingDebug += line
                self.scheduleFlush()
            }
    }

    /// Schedules a single coalesced flush ~120ms out (one is enough; further
    /// lines that arrive before it fires are folded into the same flush).
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self = self else { return }
            self.flushPending()
            self.flushTask = nil
        }
    }

    private func flushPending() {
        if !pendingTerminal.isEmpty {
            appendLog(&terminalLogs, line: pendingTerminal)
            pendingTerminal = ""
        }
        if !pendingDebug.isEmpty {
            appendLog(&debugLogs, line: pendingDebug)
            pendingDebug = ""
        }
    }

    private func appendLog(_ logStore: inout String, line: String) {
        logStore.append(line)
        if logStore.count > maxLogLength {
            let dropCount = logStore.count - maxLogLength / 2
            logStore = String(logStore.dropFirst(dropCount))
        }
    }
    
    // MARK: - Actions
    
    func clearTerminalLogs() {
        pendingTerminal = ""
        terminalLogs = ""
        logger.clear(category: .terminal)
    }

    func clearDebugLogs() {
        pendingDebug = ""
        debugLogs = ""
        logger.clear(category: .debug)
    }
    
    func copyToClipboard(_ text: String, type: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        logger.log("\(type) logs copied to clipboard", category: .debug)
    }
    
    func exportAllLogs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.message = "Export logs"
        panel.prompt = "Export"
        
        // Dynamic filename based on export type
        let timestamp = Int(Date().timeIntervalSince1970)
        switch exportType {
        case .terminal:
            panel.nameFieldStringValue = "catalyst-terminal-logs-\(timestamp).txt"
        case .system:
            panel.nameFieldStringValue = "catalyst-system-logs-\(timestamp).txt"
        case .both:
            panel.nameFieldStringValue = "catalyst-logs-\(timestamp).txt"
        }
        
        let response = panel.runModal()
        
        if response == .OK, let url = panel.url {
            let content: String
            
            switch exportType {
            case .terminal:
                content = terminalLogs.isEmpty ? "(No terminal logs)" : terminalLogs
            case .system:
                content = debugLogs.isEmpty ? "(No system logs)" : debugLogs
            case .both:
                content = """
                ========================================
                CATALYST LOGS EXPORT
                ========================================
                
                === TERMINAL OUTPUT ===
                \(terminalLogs.isEmpty ? "(No terminal logs)" : terminalLogs)
                
                === SYSTEM DIAGNOSTICS ===
                \(debugLogs.isEmpty ? "(No diagnostic logs)" : debugLogs)
                """
            }
            
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                logger.log("✅ Logs exported to \(url.lastPathComponent)", category: .debug)
            } catch {
                logger.log("❌ Failed to export logs: \(error.localizedDescription)", category: .debug)
            }
        }
    }
}
