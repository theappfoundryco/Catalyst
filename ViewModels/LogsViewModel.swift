import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A view model that coordinates live log viewing and exporting across Catalyst.
///
/// It subscribes directly to the singleton `Logger`'s publishers and handles formatting,
/// coalescing, and exporting those logs for user support.
///
/// **Caveats:**
/// - `terminalLogs` and `debugLogs` are intentionally capped at 500KB to prevent memory explosions
///   when long-running commands (like compiling Python from source) output massive blocks of text.
/// - The coalesced flushing mechanism (`scheduleFlush`) ensures high-frequency logging doesn't
///   strangle the Main thread with excessive SwiftUI renders.
///
/// ```swift
/// @StateObject var vm = LogsViewModel(logger: .shared)
/// vm.startup()
/// ```
@MainActor
final class LogsViewModel: ObservableObject {
    /// The scope of logs to be exported when saving to disk.
    enum ExportType: String, CaseIterable {
        case terminal = "Terminal"
        case system = "System"
        case both = "Both"
    }
    
    /// The accumulated plain text of all external terminal commands run by Catalyst.
    @Published var terminalLogs: String = ""
    /// The accumulated plain text of internal application diagnostics.
    @Published var debugLogs: String = ""
    /// Toggles whether the terminal log scroll view should pin to the bottom.
    @Published var terminalAutoScroll = true
    /// Toggles whether the debug log scroll view should pin to the bottom.
    @Published var debugAutoScroll = true
    /// The currently selected tab segment (0 = Terminal, 1 = Debug).
    @Published var selectedTab = 0 // 0 = Terminal, 1 = Debug
    /// The user's chosen export mode (Terminal, System, or Both).
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
    
    /// Hydrates the initial logs from the central logger and begins live subscription.
    ///
    /// **Flow:**
    /// 1. Synchronously reads the static log history buffers.
    /// 2. Sets up ``Combine`` publishers for live streaming.
    func startup() {
        // Load existing logs
        self.terminalLogs = logger.getTerminalLogs()
        self.debugLogs = logger.getDebugLogs()
        
        // Start subscriptions immediately
        subscribeToLogs()
    }
    
    /// Subscribes to the global ``Logger`` publishers for live terminal and debug events.
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

    /// Schedules a single coalesced flush ~120ms out.
    ///
    /// **Rationale:**
    /// One flush is enough; further lines that arrive before it fires are folded into the same flush.
    /// This prevents high-frequency logging loops (like `pip install`) from choking the Main thread
    /// with thousands of instant `@Published` emissions.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self = self else { return }
            self.flushPending()
            self.flushTask = nil
        }
    }

    /// Applies the accumulated pending strings to the actual published strings and clears the buffers.
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

    /// Appends a new line and forcefully truncates the top of the log if it exceeds ``maxLogLength``.
    ///
    /// - Parameters:
    ///   - logStore: The string buffer to mutate (terminal or debug).
    ///   - line: The text block to append.
    private func appendLog(_ logStore: inout String, line: String) {
        logStore.append(line)
        if logStore.count > maxLogLength {
            let dropCount = logStore.count - maxLogLength / 2
            logStore = String(logStore.dropFirst(dropCount))
        }
    }
    
    // MARK: - Actions
    
    /// Wipes all terminal history from both the VM and the backing ``Logger``.
    func clearTerminalLogs() {
        pendingTerminal = ""
        terminalLogs = ""
        logger.clear(category: .terminal)
    }

    /// Wipes all debug history from both the VM and the backing ``Logger``.
    func clearDebugLogs() {
        pendingDebug = ""
        debugLogs = ""
        logger.clear(category: .debug)
    }
    
    /// Copies a specific log string directly to the macOS general pasteboard.
    ///
    /// - Parameters:
    ///   - text: The log payload.
    ///   - type: A string identifier (e.g. "Terminal") for the success metric.
    func copyToClipboard(_ text: String, type: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        logger.log("\(type) logs copied to clipboard", category: .debug)
    }
    
    /// Presents a standard macOS Save Panel and writes the selected logs to a plain text file.
    ///
    /// **Gotchas:**
    /// - Halts the runloop awaiting the modal `runModal()` return.
    /// - Silently catches write errors and posts them only to the debug log stream.
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
