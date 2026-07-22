import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class TerminalTimeTravelViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var commands: [HistoryCommand] = []
    @Published var isRefreshing = false
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
    
    func refresh(forceRefresh: Bool = false) async {
        isRefreshing = true
        await loadHistory()
        isRefreshing = false
    }
    
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
    
    func copyToClipboard(_ command: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        Logger.shared.log("📋 Copied command to clipboard")
    }
    
    func runInTerminal(_ command: String) {
        TerminalService.shared.runCommand(command)
    }
}
