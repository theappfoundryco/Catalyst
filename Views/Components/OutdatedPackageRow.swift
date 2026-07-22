import SwiftUI
import Foundation
/// A row displaying an outdated package with its current and new versions, and an update action.
///
/// ```swift
/// OutdatedPackageRow(package: pkg, isAlternate: false, isUpdating: false, isFailed: false, onUpdate: { print("Updating") })
/// ```
struct OutdatedPackageRow: View, Equatable {
    let package: OutdatedPackage
    let isAlternate: Bool
    let isUpdating: Bool
    let isFailed: Bool
    /// Newer version exists but pip declined to install it here (constraint /
    /// Requires-Python). Rendered amber, distinct from a red hard failure.
    var isHeldBack: Bool = false
    /// Explanation shown on hover for a held-back package.
    var heldBackReason: String? = nil
    let onUpdate: () -> Void

    // R1-row: pure-value row. Compare only the inputs that affect rendering
    // (the closure is identity-irrelevant) so SwiftUI skips body when an
    // unrelated @Published on the parent screen VM changes.
    static func == (lhs: OutdatedPackageRow, rhs: OutdatedPackageRow) -> Bool {
        lhs.package == rhs.package &&
        lhs.isAlternate == rhs.isAlternate &&
        lhs.isUpdating == rhs.isUpdating &&
        lhs.isFailed == rhs.isFailed &&
        lhs.isHeldBack == rhs.isHeldBack &&
        lhs.heldBackReason == rhs.heldBackReason
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(package.name)
                        .font(.body.weight(.medium))
                    
                    // Type Badge with Python version for pip packages
                    HStack(spacing: 4) {
                        Text(package.type.displayName)
                            .font(.caption2.weight(.semibold))
                        
                        // Show Python version for pip packages
                        if package.type == .pip, let pyVersion = package.pythonVersion {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(package.type.color.opacity(0.6))
                            Text(pyVersion)
                                .font(.caption2.weight(.medium))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(package.type.color.opacity(0.15))
                    .foregroundColor(package.type.color)
                    .cornerRadius(8)
                }
                
                HStack(spacing: 6) {
                    Text(package.currentVersion)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(package.newVersion)
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            
            Spacer()
            
            if isUpdating {
                ProgressView()
                    .controlSize(.small)
            } else if isHeldBack {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Held back")
                        .font(.caption)
                        .foregroundColor(.orange)

                    Button {
                        onUpdate()
                    } label: {
                        Text("Retry")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .help(heldBackReason ?? "A newer version exists but isn't installable in this environment.")
            } else if isFailed {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text("Failed")
                        .font(.caption)
                        .foregroundColor(.red)

                    Button {
                        onUpdate()
                    } label: {
                        Text("Retry")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            } else {
                Button {
                    onUpdate()
                } label: {
                    Text("Update")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(rowBackground)
    }

    private var rowBackground: Color {
        if isFailed { return Color.red.opacity(isAlternate ? 0.05 : 0.08) }
        if isHeldBack { return Color.orange.opacity(isAlternate ? 0.05 : 0.08) }
        return isAlternate
            ? Color(NSColor.controlAlternatingRowBackgroundColors[1])
            : Color(NSColor.controlBackgroundColor)
    }
}
