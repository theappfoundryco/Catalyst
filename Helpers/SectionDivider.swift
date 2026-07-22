/// Opaque, fixed-height separator for scrolling dashboard content.

import SwiftUI

/// A 2pt **opaque** horizontal rule, used in place of `Divider()` inside
/// `ScrollView`/`VStack` content.
///
/// `Divider()` renders a single physical pixel; on a custom scroll view that
/// hairline straddles device-pixel boundaries during slow / sub-pixel scrolling
/// and visibly **shimmers**. A fixed-height opaque rectangle does not. (`Divider()`
/// is still fine inside a native `List`/`Form`, where the system manages cell
/// rendering — e.g. the sidebar.)
///
/// This is the **single source of truth** for section separators in scrolling
/// content. Replaces ad-hoc `Divider()` usage app-wide.
///
/// ```swift
/// SectionDivider(color: .gray, height: 1)
/// ```
struct SectionDivider: View {
    /// The rule color. Defaults to the adaptive system separator.
    var color: Color = Color(NSColor.separatorColor)
    /// The rule thickness. Defaults to 2pt (opaque, shimmer-free).
    var height: CGFloat = 2

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// The **vertical** counterpart to `SectionDivider`: a thin opaque rule that
/// fills the height offered by its container. Use as a column separator inside
/// an `HStack` (where `SectionDivider`, being horizontal, cannot). Fixed width
/// so it never competes with flexible siblings for horizontal space.
///
/// ```swift
/// HStack {
///     Text("Left")
///     VerticalRule()
///     Text("Right")
/// }
/// ```
struct VerticalRule: View {
    /// The rule color. Defaults to the adaptive system separator.
    var color: Color = Color(NSColor.separatorColor)
    /// The rule thickness. Defaults to 2pt (opaque, shimmer-free).
    var width: CGFloat = 2

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}
