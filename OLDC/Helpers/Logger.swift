import Foundation
import Combine

enum LogCategory {
    case terminal
    case debug
}

final class Logger {
    static let shared = Logger()
    
    private let terminalSubject = PassthroughSubject<String, Never>()
    private let debugSubject = PassthroughSubject<String, Never>()
    
    var terminalPublisher: AnyPublisher<String, Never> { terminalSubject.eraseToAnyPublisher() }
    var debugPublisher: AnyPublisher<String, Never> { debugSubject.eraseToAnyPublisher() }
    
    private let fileURL: URL
    private var appDir: URL
    private var terminalBuffer: [String] = []
    private var debugBuffer: [String] = []
    private let bufferQueue = DispatchQueue(label: "com.shivanggulati.catalyst.logger.buffer")
    
    // Serial queue for file writes to prevent race conditions
    private let fileWriteQueue = DispatchQueue(label: "com.shivanggulati.catalyst.logger.filewrite")
    
    // Log rotation settings
    private let maxLogFileSize: UInt64 = 10 * 1024 * 1024 // 10MB
    private let maxBackupCount = 3
    /// Counts file writes so we size-check periodically instead of `stat`-ing on
    /// every log line. Only touched on the serial `fileWriteQueue`.
    private var fileWriteCount = 0

    private init() {
        let fm = FileManager.default
        
        // Use do-catch instead of force unwrap for safety
        do {
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            appDir = support.appendingPathComponent("com.shivanggulati.catalyst")
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
            fileURL = appDir.appendingPathComponent("app.log")
        } catch {
            // Fallback to temp directory if Application Support fails
            appDir = fm.temporaryDirectory.appendingPathComponent("com.shivanggulati.catalyst")
            try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
            fileURL = appDir.appendingPathComponent("app.log")
            print("⚠️ Logger: Failed to create Application Support directory, using temp: \(error)")
        }
    }
    
    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy h:mm:ss a zzz"
        formatter.locale = Locale.current
        return formatter.string(from: date)
    }

    /// DEBUG-only logging. In Release the `message` autoclosure is never evaluated, so `🐛`
    /// diagnostics cost nothing in shipping builds. Used for the high-volume detection tracing.
    func debugLog(_ message: @autoclosure () -> String, category: LogCategory = .debug) {
        #if DEBUG
        log(message(), category: category)
        #endif
    }

    func log(_ line: String, category: LogCategory = .debug) {
        let ts = formatTimestamp(Date())
        let prefix = category == .terminal ? "🖥️" : "⚙️"
        let entry = "[\(ts)] \(prefix) \(line)\n"
        
        // Store in appropriate buffer
        bufferQueue.async {
            switch category {
            case .terminal:
                self.terminalBuffer.append(entry)
                if self.terminalBuffer.count > 1000 {
                    self.terminalBuffer.removeFirst(self.terminalBuffer.count - 1000)
                }
                self.terminalSubject.send(entry)
            case .debug:
                self.debugBuffer.append(entry)
                if self.debugBuffer.count > 1000 {
                    self.debugBuffer.removeFirst(self.debugBuffer.count - 1000)
                }
                self.debugSubject.send(entry)
            }
        }
        
        // Also print to console for debugging
        print(entry, terminator: "")
        
        // Append to file using serial queue to prevent race conditions
        fileWriteQueue.async {
            self.writeToFile(entry)
        }
    }
    
    /// Writes a log entry to the file with proper rotation
    private func writeToFile(_ entry: String) {
        guard let data = entry.data(using: .utf8) else { return }
        
        let fm = FileManager.default

        // Check size / rotate only every 100 writes rather than `stat`-ing the
        // file on every single log line (a syscall per line for chatty output).
        fileWriteCount += 1
        if fileWriteCount % 100 == 0,
           fm.fileExists(atPath: fileURL.path),
           let attributes = try? fm.attributesOfItem(atPath: fileURL.path),
           let fileSize = attributes[.size] as? UInt64,
           fileSize > maxLogFileSize {
            rotateLogFiles()
        }
        
        // Write to file
        if fm.fileExists(atPath: fileURL.path) {
            do {
                let fh = try FileHandle(forWritingTo: fileURL)
                defer {
                    try? fh.close()
                }
                fh.seekToEndOfFile()
                fh.write(data)
            } catch {
                // If we can't open the file, try creating a new one
                try? data.write(to: fileURL)
            }
        } else {
            try? data.write(to: fileURL)
        }
    }
    
    /// Rotates log files: app.log -> app.log.1 -> app.log.2 -> app.log.3 (deleted)
    private func rotateLogFiles() {
        let fm = FileManager.default
        
        // Delete oldest backup if it exists
        let oldestBackup = appDir.appendingPathComponent("app.log.\(maxBackupCount)")
        try? fm.removeItem(at: oldestBackup)
        
        // Rotate existing backups
        for i in stride(from: maxBackupCount - 1, through: 1, by: -1) {
            let oldPath = appDir.appendingPathComponent("app.log.\(i)")
            let newPath = appDir.appendingPathComponent("app.log.\(i + 1)")
            if fm.fileExists(atPath: oldPath.path) {
                try? fm.moveItem(at: oldPath, to: newPath)
            }
        }
        
        // Rotate current log to .1
        let backupPath = appDir.appendingPathComponent("app.log.1")
        try? fm.moveItem(at: fileURL, to: backupPath)
    }
    
    // Get all buffered logs for each category
    func getTerminalLogs() -> String {
        bufferQueue.sync {
            terminalBuffer.joined()
        }
    }
    
    func getDebugLogs() -> String {
        bufferQueue.sync {
            debugBuffer.joined()
        }
    }
    
    /// Returns the path to the log file
    func getLogFilePath() -> URL {
        return fileURL
    }

    /// Empties the in-memory buffer for a category.
    ///
    /// The Logs view reloads from these buffers on `startup()`, so without this
    /// a "Clear" that only reset the view-model's strings would repopulate on
    /// re-entry. Clearing the buffer makes the clear actually stick.
    func clear(category: LogCategory) {
        bufferQueue.async {
            switch category {
            case .terminal:
                self.terminalBuffer.removeAll()
            case .debug:
                self.debugBuffer.removeAll()
            }
        }
    }

    /// Truncates the on-disk `app.log` file. The file mixes both categories, so
    /// this clears everything persisted; call only on a full clear.
    func clearLogFile() {
        fileWriteQueue.async {
            try? Data().write(to: self.fileURL)
        }
    }
}
