/// Shared toolbar refresh button used across views that follow the
/// "spinner while loading, otherwise refresh button" pattern.

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
    
    /// Extra reason to disable the button beyond an in-flight refresh (e.g. another
    /// mutating operation is already running).
    var isDisabled: Bool = false

    /// The async action to perform when the button is tapped.
    let action: () async -> Void
    
    @State private var isRefreshing = false

    /// True while either this button's own refresh or the view model's load is in flight.
    /// Drives the label swap and the disabled state — the two must agree or the spinner can
    /// show on a button that still accepts clicks.
    private var busy: Bool { isRefreshing || isLoading }

    var body: some View {
        /// ONE Button, always — never a `ProgressView` in place of the Button.
        ///
        /// **Gotchas:** This used to branch at the top level: `if busy { ProgressView() }
        /// else { Button { … } }`. On macOS 26 that made the Liquid Glass capsule
        /// collapse around the spinner mid-refresh, because swapping the toolbar item's
        /// root view changes its identity — SwiftUI tears down the Button, and the glass
        /// container re-measures against the spinner's much smaller intrinsic width.
        ///
        /// Keeping a single Button as the stable identity and swapping only its *label*
        /// content means the glass background is measured once, from the Label, and
        /// never resizes.
        Button {
            Task {
                isRefreshing = true
                /// `defer`, not a trailing assignment (12.56). SwiftUI cancels this Task when
                /// the view goes away, so navigating off the screen mid-refresh would otherwise
                /// skip the clear and leave the button `.disabled` for the life of the view.
                defer { isRefreshing = false }
                if minimumDelay > 0 {
                    try? await Task.sleep(for: .seconds(minimumDelay))
                }
                await action()
            }
        } label: {
            /// The Label stays in the layout at zero opacity rather than being removed,
            /// so it continues to reserve its footprint and the spinner is centred over
            /// it. `.hidden()` or an `if` branch here would reintroduce the collapse.
            Label(label, systemImage: "arrow.clockwise")
                .opacity(busy ? 0 : 1)
                .overlay {
                    if busy {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    }
                }
        }
        /// Blocks re-entrancy while a refresh is in flight without changing the
        /// button's geometry — the previous implementation relied on the Button simply
        /// not existing.
        .disabled(busy || isDisabled)
        /// Accessibility: the visual label is hidden during a refresh, so state has to
        /// be announced explicitly.
        .accessibilityLabel(busy ? "\(label) in progress" : label)
    }
}
