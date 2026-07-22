/// Shared card displayed after batch package updates, showing successful
/// and failed packages with a retry option for failures.

import SwiftUI

/// A card summarising the results of a batch package update.
///
/// Accepts pre-filtered arrays of successful and failed packages so each
/// consumer can decide which subset to display (pip-only, brew-only, etc.).
///
/// ## Usage
///
/// ```swift
/// UpdateResultsSummaryCard(
///     successfulPackages: pipSuccessful,
///     failedPackages: pipFailed,
///     onDismiss: { vm.showUpdateResults = false },
///     onRetry: { name, pkg in
///         Task { await vm.updatePackage(pkg.name, type: pkg.type) }
///     }
/// )
/// ```
struct UpdateResultsSummaryCard: View {
    /// Packages that were updated successfully.
    let successfulPackages: [OutdatedPackage]
    
    /// Packages that failed to update.
    let failedPackages: [OutdatedPackage]

    /// Packages pip declined to move (newer version not installable here).
    var heldBackPackages: [OutdatedPackage] = []

    /// Reason per held-back package name, for the inline explanation.
    var heldBackReasons: [String: String] = [:]

    /// Called when the user taps the dismiss (×) button.
    let onDismiss: () -> Void
    
    /// Called when the user taps "Retry" on a failed package.
    /// Receives the package name and the full `OutdatedPackage` for context.
    let onRetry: (String, OutdatedPackage) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            
            HStack {
                Image(systemName: allClear ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundColor(allClear ? .green : .orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text(headerTitle)
                        .font(.headline)

                    /// Counts only — the status icon lives in the header above, so
                    /// we don't repeat a second green checkmark here.
                    ///
                    /// **Rationale:** Aggressive deduplication of visual iconography prevents the summary card from looking like a cluttered Christmas tree.
                    HStack(spacing: 6) {
                        Text("\(successfulPackages.count) updated")
                        if !failedPackages.isEmpty {
                            Text("·")
                            Text("\(failedPackages.count) failed")
                                .foregroundColor(.red)
                        }
                        if !heldBackPackages.isEmpty {
                            Text("·")
                            Text("\(heldBackPackages.count) held back")
                                .foregroundColor(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            SectionDivider()
            
            /// Failed packages with retry
            ///
            /// **Rationale:** Providing an immediate inline retry mechanism for transient network failures prevents users from having to restart the entire update flow.
            if !failedPackages.isEmpty {
                ResultDisclosureGroup(
                    title: "Failed Updates (\(failedPackages.count))",
                    packages: failedPackages.map(\.name),
                    status: .failed,
                    onRetry: { name in
                        if let pkg = failedPackages.first(where: { $0.name == name }) {
                            onRetry(name, pkg)
                        }
                    }
                )
            }
            
            /// Held-back packages — a newer version exists but pip won't install it
            /// in this environment. Amber, with the reason, so it reads as "blocked"
            /// rather than "failed".
            ///
            /// **Rationale:** Differentiating between hard failures and dependency conflicts (PEP 668) stops users from reporting bugs when the package manager is working exactly as designed.
            if !heldBackPackages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Held back (\(heldBackPackages.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.orange)

                    ForEach(heldBackPackages, id: \.name) { pkg in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                                Text(pkg.name)
                                    .font(.caption.monospaced())
                            }
                            if let reason = heldBackReasons[pkg.name] {
                                Text(reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.06))
                )
            }

            /// Successful packages — shown inline as a readable, wrapping paragraph
            /// on an alternate surface, so results are glanceable without expanding.
            ///
            /// **Rationale:** A dense typographic paragraph handles 50 successful updates far better than a 50-row vertical list that demands scrolling.
            if !successfulPackages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Updated (\(successfulPackages.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.green)

                    Text(successfulPackages.map(\.name).joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                )
            }
        }
        .cardStyle()
    }

    /// True only when nothing failed and nothing was held back.
    private var allClear: Bool {
        failedPackages.isEmpty && heldBackPackages.isEmpty
    }

    private var headerTitle: String {
        if allClear { return "Update Successful" }
        if failedPackages.isEmpty { return "Some Updates Held Back" }
        return "Update Partially Completed"
    }
}
