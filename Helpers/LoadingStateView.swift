import SwiftUI

/// A reusable view that displays a loading state with a progress indicator and an optional title.
///
/// Use `LoadingStateView` to indicate that a process is ongoing, such as loading data
/// or performing a background task. It centers a `ProgressView` and an optional text label
/// within its container.
///
/// ## Example Usage
/// ```swift
/// // Inline — inside a card the caller already owns.
/// LoadingStateView("Loading Packages...")
///
/// // Standalone — owns its slot and draws its own card.
/// LoadingStateView("Scanning for updates...", verticalPadding: 60, prominence: .standalone)
/// ```
///
/// - Important: A loading state and the empty state that replaces it **must use
///   the same prominence**. Mismatching them makes the card background appear or
///   vanish the moment loading finishes, which reads as a layout glitch. Git
///   Graph had exactly this bug in two places before the states were unified.
struct LoadingStateView: View {
    /// Mirrors ``EmptyStateView/Prominence`` so a loading state and the empty
    /// state that replaces it can be kept visually identical.
    enum Prominence {
        /// Nested inside a card the caller already provides.
        case inline
        /// A standalone block that supplies its own `cardStyle()` background.
        case standalone
    }

    /// The text to display below the progress indicator.
    var title: String?

    /// The vertical padding applied to the loading state container.
    var verticalPadding: CGFloat

    /// Visual weight, and whether this view supplies its own card background.
    var prominence: Prominence

    /// Whether the standalone card carries the outer horizontal margin.
    var cardPadded: Bool

    /// Initializes a new LoadingStateView.
    /// - Parameters:
    ///   - title: An optional message to display below the spinner.
    ///   - verticalPadding: Padding applied to top and bottom. Defaults to 16.
    ///   - prominence: Whether the view draws its own card. Defaults to `.inline`.
    ///   - cardPadded: Outer horizontal margin for `.standalone`. Defaults to `true`.
    init(
        _ title: String? = nil,
        verticalPadding: CGFloat = 16,
        prominence: Prominence = .inline,
        cardPadded: Bool = true
    ) {
        self.title = title
        self.verticalPadding = verticalPadding
        self.prominence = prominence
        self.cardPadded = cardPadded
    }

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)

            if let title = title {
                Text(title)
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            }
        }
        /// Inline fills its container vertically (long-standing behaviour that
        /// centres it in a fixed-height panel). Standalone must not — an
        /// unbounded height inside a card stretches the card down the page.
        .frame(
            maxWidth: .infinity,
            maxHeight: prominence == .standalone ? nil : .infinity
        )
        .padding(.vertical, verticalPadding)
        .modifier(LoadingStateCardModifier(
            isCarded: prominence == .standalone,
            padded: cardPadded
        ))
    }
}

/// Applies `cardStyle()` only for standalone loading states.
private struct LoadingStateCardModifier: ViewModifier {
    let isCarded: Bool
    let padded: Bool

    func body(content: Content) -> some View {
        if isCarded {
            content.cardStyle(.standard, padded: padded)
        } else {
            content
        }
    }
}
