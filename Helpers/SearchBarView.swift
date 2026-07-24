/// Centralized search bar with magnifying glass icon.

import SwiftUI

/// A reusable search bar with a magnifying glass icon and recessed code-panel background.
///
/// Used for filtering lists, searching packages, and browsing shortcuts.
///
/// ## Usage
///
/// ```swift
/// // Simple filter bar:
/// SearchBarView(placeholder: "Search in formulae...", text: $query)
///
/// // With submit action:
/// SearchBarView(placeholder: "Enter package name...", text: $query) {
///     Task { await vm.search() }
/// }
/// ```
struct SearchBarView: View {
    /// Placeholder text displayed when the field is empty.
    let placeholder: String
    
    /// Binding to the search query text.
    @Binding var text: String
    
    /// Optional action triggered on Return key press.
    var onSubmit: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.caption)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .if(onSubmit != nil) { view in
                    view.onSubmit { onSubmit?() }
                }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .appButton(.plain)
            }
        }
        /// Match CompactInputField exactly so search bars and form fields are
        /// visually identical app-wide (the app's single field look).
        ///
        /// **Rationale:** Enforcing a single unified field component prevents the app from looking like a patchwork of slightly different SwiftUI default styles.
        .padding(4)
        .cardStyle(.compact, padded: false)
        /// Whole bar is the tap target, not just the text.
        ///
        /// **Gotchas:** Without an explicit `contentShape`, clicking the padding area between the magnifying glass and the text will fail to focus the field.
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }
}

/// Conditional modifier helper for SearchBarView.
private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
