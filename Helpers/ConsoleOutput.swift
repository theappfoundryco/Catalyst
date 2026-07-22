import SwiftUI
import Combine

/// A tiny observable that owns streaming command/console output.
///
/// **Why (R2):** install screens append chunk-by-chunk (the process runner
/// flushes ~every 0.1s) onto the *screen's* god view-model. Because the whole
/// screen observes that VM, every chunk re-renders the entire catalog + search.
/// Moving the text into its own `ConsoleOutput` — observed *only* by
/// `ConsoleOutputView` — means a chunk re-renders just the console card.
/// Appends are also coalesced (~120ms) so a burst of lines is one render, not N.
///
/// ## Rollout pattern
/// ```swift
/// // In the VM:
/// let console = ConsoleOutput()
/// // streaming callback:
/// runner.runWithStreaming(...) { chunk in self.console.append(chunk) }
///
/// // In the View — pass the stable object, don't read its text in the parent:
/// ConsoleOutputView(console: vm.console, title: "Installation Output")
/// ```
@MainActor
final class ConsoleOutput: ObservableObject {
    @Published private(set) var text: String = ""

    /// Hard cap so a long-running command can't grow the string unbounded.
    private let maxLength = 200_000

    private var pending = ""
    private var flushTask: Task<Void, Never>?

    /// Append a chunk. Publishing is coalesced; callers can fire freely.
    /// - Parameter chunk: A sequential slice of output targeting the buffer.
    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        pending += chunk
        scheduleFlush()
    }

    /// Replace the whole buffer immediately (e.g. seeding or clearing).
    /// - Parameter value: The explicit text replacing the current buffer.
    func set(_ value: String) {
        flushTask?.cancel()
        flushTask = nil
        pending = ""
        text = value
    }

    /// Purges all active text from the terminal display.
    /// - Returns: Nil. Executes buffer clearance.
    func clear() { set("") }

    var isEmpty: Bool { text.isEmpty && pending.isEmpty }

    /// Throttles standard output rendering to preserve SwiftUI scrolling performance during burst updates.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self else { return }
            self.flush()
            self.flushTask = nil
        }
    }

    /// Applies pending stream data directly into the active UI state property.
    private func flush() {
        guard !pending.isEmpty else { return }
        text += pending
        pending = ""
        if text.count > maxLength {
            text = String(text.dropFirst(text.count - maxLength / 2))
        }
    }
}

/// Observing wrapper around `OutputConsoleView`. Because this view (not the
/// parent screen) holds the `@ObservedObject`, appends re-render only this card.
/// Renders nothing until there's output, so the parent doesn't need to read the
/// text to gate visibility.
///
/// ```swift
/// ConsoleOutputView(console: vm.console, title: "Installation Output")
/// ```
struct ConsoleOutputView: View {
    @ObservedObject var console: ConsoleOutput
    var title: String = "Installation Output"
    var maxHeight: CGFloat = 200

    var body: some View {
        if !console.text.isEmpty {
            OutputConsoleView(
                output: console.text,
                onClear: { console.clear() },
                title: title,
                maxHeight: maxHeight
            )
        }
    }
}
