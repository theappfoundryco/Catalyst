import Foundation
import SwiftUI
import AppKit
import Combine

/// A view model that coordinates parsing and presenting local shell history files.
///
/// It scans `~/.zsh_history` (or `~/.bash_history`) safely off the main thread, strips
/// binary artifacts or bad encodings, and reverses the timeline so the most recent
/// commands surface at the top.
///
/// **Caveats:**
/// - Loading requires detached tasks. Shell history files can contain literal null bytes,
///   ANSI codes, and mangled UTF-8 that crash simplistic decoders.
///
/// ```swift
/// @StateObject var vm = TerminalTimeTravelViewModel()
/// await vm.refresh()
/// ```
@MainActor
final class TerminalTimeTravelViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    /// The decoded, reversed array of history commands.
    @Published var commands: [HistoryCommand] = []
    /// Indicates whether a history sweep is actively running.
    @Published var isRefreshing = false
    /// Surfaceable error text if the file is missing or utterly unreadable.
    @Published var errorMessage: String?
    
    // MARK: - Models
    
    struct HistoryCommand: Identifiable {
        let id = UUID()
        let index: Int
        let command: String
    }
    
    // MARK: - Initialization
    
    init() {
        // Async load on init
        Task {
            await loadHistory()
        }
    }
    
    // MARK: - Public Methods
    
    /// Manually triggers a reload of the history file.
    ///
    /// - Parameter forceRefresh: Optional flag to dictate cache bypassing (unused logically, maintained for protocol conformance).
    func refresh(forceRefresh: Bool = false) async {
        isRefreshing = true
        await loadHistory()
        isRefreshing = false
    }
    
    /// Scans the file system for `.zsh_history` or `.bash_history` and decodes it.
    ///
    /// **Flow:**
    /// 1. Detaches a `.userInitiated` background task to avoid blocking the main thread with heavy file I/O.
    /// 2. Reads the raw data blob from `~/.zsh_history` (or bash fallback).
    /// 3. Sequentially attempts to decode as `UTF-8`, `ISO-Latin-1`, or lossy ASCII to survive malformed bytes.
    /// 4. Parses the ZSH timestamp headers (`: 1612345678:0;`) out of the string if present.
    /// 5. Reverses the chronology (newest first) and limits to the last 500 commands.
    func loadHistory() async {
        errorMessage = nil
        
        // Move file I/O and parsing to background thread
        let result = await Task.detached(priority: .userInitiated) { () -> ([HistoryCommand], String?) in
            // Try zsh first (default macOS shell since Catalina)
            let zshHistoryPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zsh_history")
            let bashHistoryPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bash_history")
            
            var historyPath: URL?
            if FileManager.default.fileExists(atPath: zshHistoryPath.path) {
                historyPath = zshHistoryPath
            } else if FileManager.default.fileExists(atPath: bashHistoryPath.path) {
                historyPath = bashHistoryPath
            }
            
            guard let path = historyPath else {
                return ([], "No shell history found (~/.zsh_history or ~/.bash_history)")
            }
            
            do {
                // Read as Data first to handle potential binary artifacts
                let data = try Data(contentsOf: path)
                
                // Convert with lossy encoding (replaces invalid bytes)
                // Try UTF-8 first, fall back to ASCII
                var content: String
                if let utf8Content = String(data: data, encoding: .utf8) {
                    content = utf8Content
                } else if let isoContent = String(data: data, encoding: .isoLatin1) {
                    // isoLatin1 never fails - maps bytes 1:1
                    content = isoContent
                } else {
                    // Last resort: manual ASCII with replacement
                    content = String(decoding: data, as: UTF8.self)
                }
                
                let lines = content.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty }
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                
                // Parse zsh history format (may have : timestamp:0;command format)
                var parsedCommands: [HistoryCommand] = []
                
                // Helper parsing logic (inline to be safe in detached task context)
                /// - Parameter line: The raw unparsed text output from the terminal stream.
                /// - Returns: A sanitized text representation safe for presentation.
                func parseLine(_ line: String) -> String {
                    if line.hasPrefix(": ") && line.contains(";") {
                        if let semicolonIndex = line.firstIndex(of: ";") {
                            let commandStart = line.index(after: semicolonIndex)
                            // Safe slicing
                            return String(line[commandStart...])
                        }
                    }
                    return line
                }
                
                for (index, line) in lines.enumerated() {
                    let command = parseLine(line)
                    // Filter out non-printable commands and very short noise
                    if !command.isEmpty && command.count > 1 && command.allSatisfy({ $0.isASCII || $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isWhitespace }) {
                        parsedCommands.append(HistoryCommand(index: index + 1, command: command))
                    }
                }
                
                // Reverse to show most recent first, limit to last 500
                let finalCommands = Array(parsedCommands.reversed().prefix(500))
                
                if finalCommands.isEmpty && !lines.isEmpty {
                    return ([], "History file found but no valid commands parsed")
                }
                
                return (finalCommands, nil)
                
            } catch {
                return ([], "Failed to read history: \(error.localizedDescription)")
            }
        }.value
        
        // Update on Main Actor
        self.commands = result.0
        self.errorMessage = result.1
    }
    
    /// Copies a specific history command strictly to the macOS general pasteboard.
    ///
    /// - Parameter command: The raw shell string to copy.
    func copyToClipboard(_ command: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        Logger.shared.log("📋 Copied command to clipboard")
    }
    
    /// Invokes the shared terminal service to open a new window executing the command.
    ///
    /// - Parameter command: The literal string to inject and run.
    func runInTerminal(_ command: String) {
        TerminalService.shared.runCommand(command)
    }
}
