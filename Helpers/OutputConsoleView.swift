/// Centralized installation/output console card.

import SwiftUI

/// A reusable card that displays monospaced terminal-style output with a Clear button.
///
/// Used for installation logs, command output, and diagnostic consoles throughout the app.
///
/// ## Usage
///
/// ```swift
/// if !vm.installationOutput.isEmpty {
///     OutputConsoleView(
///         output: vm.installationOutput,
///         onClear: { vm.clearOutput() }
///     )
/// }
/// ```
struct OutputConsoleView: View {
    /// The monospaced text content to display.
    let output: String
    
    /// Called when the user taps the Clear button.
    let onClear: () -> Void
    
    /// The headline title shown at the top of the card. Defaults to `"Installation Output"`.
    var title: String = "Installation Output"
    
    /// Maximum height for the scroll area. Defaults to `200`.
    var maxHeight: CGFloat = 200
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title)
                    .font(.headline)
                
                Spacer()
                
                Button {
                    onClear()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .labelStyle(.matched)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            SectionDivider()
            
            ScrollView {
                Text(output)
                    .font(.caption.monospaced())
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxHeight)
            /// Yield the scroll wheel to the page scroll when output fits; keeps
            /// independent scrolling for long logs without the nested-scroll jerk
            ///
            /// **Rationale:** Solves the notorious SwiftUI "scroll trap" where a short embedded scroll view steals wheel events from the parent page.
            // and removes the boundary rubber-band (ANTI_PATTERNS.md Rule 1).
            .scrollBounceBehavior(.basedOnSize)
            .codePanel()
        }
        .cardStyle()
    }
}
