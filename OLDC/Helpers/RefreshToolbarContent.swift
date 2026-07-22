//
//  RefreshToolbarContent.swift
//  Catalyst
//
//  Shared toolbar refresh button used across views that follow the
//  "spinner while loading, otherwise refresh button" pattern.
//

import SwiftUI

/// A reusable toolbar button that shows a spinner while loading and a refresh button otherwise.
///
/// This replaces the boilerplate pattern of declaring `@State private var isRefreshing`
/// and manually managing the spinner/button toggle in every view.
///
/// ## Usage
///
/// ```swift
/// .toolbar {
///     ToolbarItem(placement: .primaryAction) {
///         RefreshToolbarContent(
///             isLoading: vm.isLoading,
///             action: { await vm.refresh() }
///         )
///     }
/// }
/// ```
///
/// With custom label and delay:
///
/// ```swift
/// RefreshToolbarContent(
///     isLoading: vm.isLoading,
///     label: "Re-Scan",
///     minimumDelay: 1.5,
///     action: { await vm.scan() }
/// )
/// ```
struct RefreshToolbarContent: View {
    /// Whether the associated ViewModel is currently loading data.
    let isLoading: Bool
    
    /// The label text displayed on the refresh button.
    var label: String = "Refresh"
    
    /// Minimum delay (in seconds) before the spinner stops, to avoid visual flicker.
    /// Set to `0` to skip the delay.
    var minimumDelay: Double = 0.5
    
    /// The async action to perform when the button is tapped.
    let action: () async -> Void
    
    @State private var isRefreshing = false
    
    var body: some View {
        if isRefreshing || isLoading {
            ProgressView()
                .controlSize(.small)
        } else {
            Button {
                Task {
                    isRefreshing = true
                    if minimumDelay > 0 {
                        try? await Task.sleep(for: .seconds(minimumDelay))
                    }
                    await action()
                    isRefreshing = false
                }
            } label: {
                Label(label, systemImage: "arrow.clockwise")
            }
        }
    }
}
