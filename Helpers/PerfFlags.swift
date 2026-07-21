import SwiftUI

/// Runtime-tweakable performance switches. Centralized so an experiment is one
/// flip + rebuild, not a scatter of edits.
enum PerfFlags {
    /// Flatten purely-visual cards into a single GPU texture while scrolling via
    /// `.drawingGroup()`. The compositor then moves one rasterized image per card
    /// instead of re-compositing many gradient/stroke sublayers every frame.
    ///
    /// Flip to `false` to A/B against the normal layered renderer. If text looks
    /// softer or anything renders oddly, turn it off — Instruments showed no
    /// hitches, so this is a subjective-smoothness experiment, not a fix.
    static let rasterizeScrollCards = false
}

extension View {
    /// Applies `.drawingGroup()` to a card when `PerfFlags.rasterizeScrollCards`
    /// is on. **Use only on non-interactive content** — `drawingGroup()`
    /// rasterizes the whole subtree, which can disrupt popover/sheet anchoring,
    /// text-field focus rings, and live animations on interactive controls.
    @ViewBuilder
    func rasterizedCard() -> some View {
        if PerfFlags.rasterizeScrollCards {
            self.drawingGroup()
        } else {
            self
        }
    }
}
