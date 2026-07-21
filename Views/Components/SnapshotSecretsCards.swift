//
//  SnapshotSecretsCards.swift
//  Catalyst
//
//  The surfaces that front the encrypted-secrets flow in Snapshot & Migrate:
//  `SnapshotSecretsCaptureSheet` (asked at capture time), `SnapshotSecretsUnlockCard`
//  (Migrate, with Validate), and `SnapshotSecretsPendingCard` +
//  `SnapshotSecretsUnlockSheet` (the standalone "I remembered it later" path).
//
//  They live here rather than inline in `SnapshotView` for the same reason the
//  Dashboard/Cruft cards do: `SnapshotView` is already a long file of flow logic,
//  and these two are pure presentation over a couple of bindings. Both are driven
//  entirely by `@Binding`, so they hold no state of their own and never touch the
//  view model — the passphrase string is owned by `SnapshotViewModel` and cleared
//  there the moment it's been used.
//
//  Both reuse the app's shared building blocks (`CompactInputField`, `cardStyle()`,
//  `SectionDivider`) so they match every other input surface in Catalyst instead of
//  introducing a second, bespoke text-field look.
//

import SwiftUI

/// Shared chrome for the two secrets cards: purple lock-family badge, title,
/// subtitle, and an optional trailing control. Keeps the pair visually identical
/// so the same feature reads the same on both sides of the flow.
private struct SecretsCardHeader<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.purple)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.bold())
                Text(subtitle)
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

/// A one-line cautionary note with a leading warning glyph.
private struct SecretsWarningNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundColor(.orange)
                .padding(.top, 2)
            Text(text)
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Inline result of a Validate check. Because AES-GCM is authenticated, "valid"
/// and "invalid" are both definitive — this never says "probably".
struct SecretsValidationLabel: View {
    let state: SnapshotViewModel.SecretsValidation

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption2).foregroundColor(.secondary)
            }
        case .valid(let n):
            Label("Correct — unlocks \(n) secret(s)", systemImage: "checkmark.circle.fill")
                .labelStyle(.matched)
                .font(.caption2).foregroundColor(.green)
        case .invalid:
            Label("That passphrase won't unlock these secrets", systemImage: "xmark.octagon.fill")
                .labelStyle(.matched)
                .font(.caption2).foregroundColor(.red)
        }
    }
}

/// Passphrase field + Validate button. Shared by the Migrate card, the capture
/// sheet, and the standalone unlock sheet so the control behaves identically
/// wherever a passphrase is asked for.
struct SecretsPassphraseField: View {
    var label: String? = nil
    var placeholder: String = "Passphrase"
    @Binding var passphrase: String
    var validation: SnapshotViewModel.SecretsValidation = .idle
    /// Omit to render the field without a Validate button (capture side, where
    /// there's nothing yet to validate against).
    var onValidate: (() -> Void)? = nil
    var disabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CompactInputField(
                    label: label,
                    icon: "lock",
                    placeholder: placeholder,
                    text: $passphrase,
                    isSecure: true,
                    onSubmit: onValidate
                )
                .disabled(disabled)

                if let onValidate {
                    Button("Validate", action: onValidate)
                        .buttonStyle(.bordered)
                        .disabled(disabled || passphrase.isEmpty || validation == .checking)
                        // Align with the field, not its caption label.
                        .padding(.top, label == nil ? 0 : 18)
                }
            }
            SecretsValidationLabel(state: validation)
        }
    }
}

// MARK: - Capture side

/// Asked at the moment Capture is clicked. Encryption is opt-in by *typing a
/// passphrase* — there's no separate toggle to forget, and the "capture without"
/// path is always one click away.
struct SnapshotSecretsCaptureSheet: View {
    @Binding var passphrase: String
    var isWorking: Bool = false
    let onCapture: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SecretsCardHeader(
                icon: "key.horizontal.fill",
                title: "Include API Secrets?",
                subtitle: "Catalyst can seal the API keys and tokens from your ~/.zshrc into this snapshot, encrypted with a passphrase only you know."
            ) { EmptyView() }

            SectionDivider()

            SecretsPassphraseField(
                label: "Encryption passphrase",
                placeholder: "Leave blank to skip",
                passphrase: $passphrase,
                disabled: isWorking
            )

            SecretsWarningNote(text: "Only this passphrase can decrypt them. Catalyst does not store it and cannot recover it — if you lose it the secrets are gone for good, though everything else in the snapshot still restores normally. Keep the snapshot file: you can unlock the secrets from it later.")

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Spacer()
                Button(action: onCapture) {
                    Text(passphrase.isEmpty ? "Capture Without Secrets" : "Capture With Encryption")
                        .fontWeight(.semibold)
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(isWorking)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

// MARK: - Restore side

/// Passphrase entry for a snapshot that carries sealed secrets, with an explicit
/// Validate that checks WITHOUT restoring anything.
///
/// Framed as optional throughout: a blank or wrong passphrase marks that single
/// row "skipped" and leaves every other step of the restore untouched — and the
/// placeholders stay in `~/.zshrc`, so it can be applied later.
struct SnapshotSecretsUnlockCard: View {
    let count: Int
    @Binding var passphrase: String
    var validation: SnapshotViewModel.SecretsValidation = .idle
    var disabled: Bool = false
    let onValidate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecretsCardHeader(
                icon: "lock.fill",
                title: "Encrypted Secrets (\(count))",
                subtitle: "This snapshot carries \(count) sealed API secret(s). Validate the passphrase here before restoring."
            ) { EmptyView() }

            SecretsPassphraseField(
                passphrase: $passphrase,
                validation: validation,
                onValidate: onValidate,
                disabled: disabled
            )

            Text("Optional — leave it blank and the secrets stay sealed. Everything else restores either way, and you can unlock them later from this snapshot file.")
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }
}

// MARK: - Standalone unlock

/// Shown on the Snapshot landing whenever `~/.zshrc` still holds Catalyst
/// placeholders — i.e. secrets were captured but never unlocked.
///
/// This exists so the app finds the user rather than the reverse: nobody should
/// have to remember that they skipped a passphrase three days ago, and nobody
/// should have to redo the whole Migrate journey to act on it.
struct SnapshotSecretsPendingCard: View {
    let count: Int
    var disabled: Bool = false
    let onUnlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecretsCardHeader(
                icon: "lock.trianglebadge.exclamationmark.fill",
                title: "\(count) Secret(s) Still Sealed",
                subtitle: "Your ~/.zshrc has \(count) placeholder value(s) from a restored snapshot. Unlock them any time with the passphrase — no need to run Migrate again."
            ) { EmptyView() }

            Button(action: onUnlock) {
                Label("Unlock from Snapshot…", systemImage: "lock.open")
                    .labelStyle(.matched)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(disabled)
        }
        .cardStyle()
    }
}

/// The standalone unlock sheet: pick a snapshot, validate, apply. No import, no
/// diff, no restore — this path touches only placeholder lines in `~/.zshrc`.
struct SnapshotSecretsUnlockSheet: View {
    let count: Int
    @Binding var passphrase: String
    var validation: SnapshotViewModel.SecretsValidation = .idle
    var result: String?
    var isWorking: Bool = false
    let onValidate: () -> Void
    let onApply: () -> Void
    let onCancel: () -> Void

    private var canApply: Bool {
        if case .valid = validation { return !isWorking }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SecretsCardHeader(
                icon: "lock.open.fill",
                title: "Unlock Encrypted Secrets",
                subtitle: "This snapshot holds \(count) sealed secret(s). Validate the passphrase, then apply them to your ~/.zshrc."
            ) { EmptyView() }

            SectionDivider()

            SecretsPassphraseField(
                label: "Passphrase",
                passphrase: $passphrase,
                validation: validation,
                onValidate: onValidate,
                disabled: isWorking
            )

            if let result {
                Text(result).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Only values still showing the Catalyst placeholder are replaced — anything you've already set by hand is left alone.")
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Close", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Spacer()
                Button(action: onApply) {
                    Text("Apply Secrets")
                        .fontWeight(.semibold)
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.large)
                .disabled(!canApply)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
