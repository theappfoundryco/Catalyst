/// Centralized empty/no-results state placeholder.

import SwiftUI

/// A reusable placeholder view for empty or no-results states.
///
/// Displays a centered icon, a primary message, and an optional detail line.
/// Used throughout the app whenever a list, grid, or section has nothing to show.
///
/// ## Usage
///
/// ```swift
/// // Basic empty state:
/// EmptyStateView(icon: "tray", message: "No packages installed")
///
/// // With detail line:
/// EmptyStateView(
///     icon: "tray",
///     message: "No Aliases Found",
///     detail: "Create your first alias above to get started!"
/// )
///
/// // Custom icon color (e.g., for errors):
/// EmptyStateView(
///     icon: "exclamationmark.triangle",
///     message: "Something went wrong",
///     iconColor: .orange
/// )
/// ```
///
/// ## Prominence
///
/// Two shapes, because the app genuinely needs both:
///
/// ```swift
/// // Inline — the default. Sits inside a card the caller already owns
/// // (below a SectionDivider, inside a results panel). Quiet and compact.
/// EmptyStateView(icon: "tray", message: "No pip packages installed")
///
/// // Standalone — owns its slot on the page. Emphasised title and it draws
/// // its OWN card, so it never floats in dead space.
/// EmptyStateView(
///     icon: "checkmark.circle.fill",
///     message: "All pip packages are up to date!",
///     detail: "No updates available at this time",
///     iconColor: .green,
///     prominence: .standalone
/// )
/// ```
///
/// - Important: Pick `.standalone` whenever the empty state is a direct child of
///   a page `VStack` rather than a child of an existing card. Applying
///   `.cardStyle()` to an `.inline` one by hand is the old pattern — it produced
///   four near-identical hand-rolled copies of this view across the app because
///   the emphasised-title shape wasn't expressible here. It is now; don't
///   re-roll it.
///
/// - Note: Wraps itself in `.frame(maxWidth: .infinity)` and vertical padding
///   so it fills the available width and centers naturally within a card or scroll view.
struct EmptyStateView: View {
    /// How much visual weight the state carries, and whether it draws its own card.
    enum Prominence {
        /// Nested inside a card the caller already provides. Secondary, compact,
        /// no background of its own.
        case inline
        /// A standalone block on the page: emphasised title, larger icon, and its
        /// own `cardStyle()` background.
        case standalone
    }

    /// SF Symbol name for the icon.
    let icon: String

    /// Primary message displayed below the icon.
    let message: String

    /// Optional secondary detail text, shown in a smaller font below the message.
    var detail: String? = nil

    /// Icon color. Defaults to `.secondary`.
    var iconColor: Color = .secondary

    /// Icon font size. `nil` derives it from ``prominence`` (40 inline, 48 standalone).
    var iconSize: CGFloat? = nil

    /// Vertical padding around the content. `nil` derives it from ``prominence``
    /// (40 inline, 40 standalone — the card supplies the rest).
    var verticalPadding: CGFloat? = nil

    /// Visual weight, and whether this view supplies its own card background.
    var prominence: Prominence = .inline

    /// Whether the standalone card carries the outer horizontal margin. Set
    /// `false` when the parent already applies its own horizontal padding.
    /// Ignored when ``prominence`` is `.inline`.
    var cardPadded: Bool = true

    /// Resolved icon size.
    private var resolvedIconSize: CGFloat {
        iconSize ?? (prominence == .standalone ? 48 : 40)
    }

    /// Resolved vertical padding.
    private var resolvedPadding: CGFloat {
        verticalPadding ?? 40
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .padding(.vertical, resolvedPadding)
            /// `.standalone` draws its own card so the state can never end up
            /// floating on the page background — the failure this variant exists
            /// to prevent.
            .modifier(EmptyStateCardModifier(
                isCarded: prominence == .standalone,
                padded: cardPadded
            ))
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: resolvedIconSize))
                .foregroundColor(iconColor)

            /// Standalone states title the result; inline ones stay quiet so they
            /// don't compete with the card heading directly above them.
            Text(message)
                .font(prominence == .standalone ? .headline : .subheadline)
                .foregroundColor(prominence == .standalone ? .primary : .secondary)
                .multilineTextAlignment(.center)

            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Applies `cardStyle()` only for standalone empty states.
///
/// A modifier rather than an `if` in `body` so both branches return the same
/// concrete view type and SwiftUI keeps the view's identity stable.
private struct EmptyStateCardModifier: ViewModifier {
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
