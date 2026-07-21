//
//  ResultDisclosureGroup.swift
//  Catalyst
//
//  Centralized success/failed package result disclosure groups.
//
import SwiftUI

/// The result status of a package operation, determining the color and icon.
enum ResultStatus {
    /// Green checkmark — operation succeeded.
    case success
    /// Red X — operation failed.
    case failed
    
    var color: Color {
        switch self {
        case .success: return .green
        case .failed: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
}

/// A reusable disclosure group that lists package names with a colored status icon.
///
/// Used after update/install operations to show which packages succeeded or failed.
///
/// ## Usage
///
/// ```swift
/// // Success list (names only):
/// ResultDisclosureGroup(
///     title: "Successfully Updated (5)",
///     packages: successfulNames,
///     status: .success
/// )
///
/// // Failed list with retry buttons:
/// ResultDisclosureGroup(
///     title: "Failed Updates (2)",
///     packages: failedNames,
///     status: .failed,
///     onRetry: { name in
///         Task { await vm.retryPackage(name) }
///     }
/// )
/// ```
struct ResultDisclosureGroup: View {
    /// The label text shown in the disclosure header.
    let title: String
    
    /// The list of package names to display.
    let packages: [String]
    
    /// Whether this represents a success or failure result.
    let status: ResultStatus
    
    /// Optional retry action per package. When provided, each row gets a "Retry" button.
    var onRetry: ((String) -> Void)? = nil
    
    /// Optional dismiss action. When provided, an X button appears in the header to dismiss the group.
    var onDismiss: (() -> Void)? = nil
    
    /// Maximum height for the scrollable list. Defaults to `100`.
    var maxHeight: CGFloat = 100
    
    var body: some View {
        DisclosureGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: onRetry != nil ? 8 : 4) {
                    ForEach(packages, id: \.self) { package in
                        HStack(spacing: 8) {
                            Image(systemName: status.icon)
                                .foregroundColor(status.color)
                                .font(.caption)
                            
                            Text(package)
                                .font(.caption.monospaced())
                            
                            if let onRetry {
                                Spacer()
                                
                                Button {
                                    onRetry(package)
                                } label: {
                                    Text("Retry")
                                        .font(.caption2)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxHeight)
            .scrollBounceBehavior(.basedOnSize) // toAvoid.md Rule 1
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(status.color.opacity(0.05))
            )
        } label: {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(status.color)
                
                if let onDismiss {
                    Spacer()
                    
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
