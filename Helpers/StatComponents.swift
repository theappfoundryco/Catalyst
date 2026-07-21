//
//  StatComponents.swift
//  Catalyst
//
//  Shared stat display components used across DrCatalyst and SSD Health views.
//

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
