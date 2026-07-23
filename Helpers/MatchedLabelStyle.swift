/// Shared label style that keeps a button's SF Symbol the same color as its title.

import SwiftUI

/// Renders a `Label` so its SF Symbol always matches the title's color.
///
/// macOS renders several SF Symbols in their own multicolor/hierarchical palette
/// (or tints only the glyph), which leaves a mismatched "random" icon color next
/// to neutral title text on action buttons. Forcing `.monochrome` makes the
/// symbol adopt the same foreground the button assigns to the title, so icon and
/// text always match — in `.bordered` (tinted/neutral) and `.borderedProminent`
/// (white-on-fill) alike.
///
/// ## Usage
/// ```swift
/// Button { … } label: {
///     Label("Scan for Updates", systemImage: "arrow.clockwise")
/// }
/// .labelStyle(.matched)
/// ```
struct MatchedLabelStyle: LabelStyle {
    var spacing: CGFloat = 4

    /// Fuses the system icon and text components into a uniform visual hierarchy.
    /// - Parameter configuration: The active structural bridge mapping the style attributes.
    /// - Returns: The active presentation hierarchy for the detail view.
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
        .symbolRenderingMode(.monochrome)
    }
}

extension LabelStyle where Self == MatchedLabelStyle {
    /// Icon color always follows the title color. See ``MatchedLabelStyle``.
    static var matched: MatchedLabelStyle { MatchedLabelStyle() }
}
