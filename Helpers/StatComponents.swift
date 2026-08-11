/// Shared stat display components used across DrCatalyst and SSD Health views.

import SwiftUI

// MARK: - Stat Badge (Small)

/// A compact badge showing a count and label with a color accent.
///
/// Used in dashboard headers to display issue breakdowns (Critical, Warnings, Info).
///
/// ## Usage
///
/// ```swift
/// StatBadge_Small(count: 3, label: "Critical", color: .red)
/// ```
struct StatBadge_Small: View {
    let count: Int
    let label: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.title2.bold())
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Stat Column Header

/// A vertical stat column showing a label, value, and subtext.
///
/// Automatically highlights subtext in red if it contains "Critical" or "High".
///
/// ## Usage
///
/// ```swift
/// StatColumnHeader(label: "Temperature", value: "42°C", subtext: "Normal")
/// ```
struct StatColumnHeader: View {
    let label: String
    let value: String
    let subtext: String
    
    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.title3.weight(.medium))
                .foregroundColor(.primary)
            
            Text(subtext)
                .font(.caption)
                .foregroundColor(subtext.contains("Critical") || subtext.contains("High") ? .red : .secondary)
        }
    }
}

// MARK: - Proportional Breakdown Bar

/// One slice of a ``ProportionalBreakdownBar``.
struct BreakdownSegment: Identifiable {
    /// Stable identity for SwiftUI diffing.
    let id: String
    /// The slice's fill color — normally the owning category's accent.
    let color: Color
    /// The byte size this slice represents.
    let size: Int64
}

/// A single capsule bar split proportionally by category size.
///
/// **Single source of truth** for the "where did the space go" bar. Cruft Sweeper
/// and Orphanage both lead their results card with one, so it lives here rather
/// than privately inside either feature — the two must stay pixel-identical
/// (height 10, 1pt gaps, `Capsule` clip, 2pt minimum slice so a tiny category
/// stays visible).
///
/// ```swift
/// ProportionalBreakdownBar(
///     segments: breakdown.map { BreakdownSegment(id: $0.id, color: $0.color, size: $0.size) },
///     total: totalBytes
/// )
/// ```
struct ProportionalBreakdownBar: View {
    /// The slices, in display order (largest first by convention).
    let segments: [BreakdownSegment]
    /// Denominator for the proportions.
    let total: Int64

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments) { seg in
                    Rectangle()
                        .fill(seg.color)
                        .frame(width: max(2, geo.size.width * fraction(seg)))
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
    }

    /// This segment's share of the total.
    /// - Parameter seg: The slice being measured.
    /// - Returns: A 0…1 fraction, or 0 when the total is empty.
    private func fraction(_ seg: BreakdownSegment) -> CGFloat {
        total > 0 ? CGFloat(Double(seg.size) / Double(total)) : 0
    }
}
