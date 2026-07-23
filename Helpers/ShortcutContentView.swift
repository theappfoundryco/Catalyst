/// Native, reusable renderer for a shortcut's structured detail content.
/// Replaces MarkdownUI: predefined, native components — no markdown parsing,
/// no raw code reveal, no nested scroll views.
/// Redesign (2026-07): the sections are consolidated into a SINGLE card with
/// light sub-headers and hairline dividers (instead of one heavy card per
/// section), for a calmer, more concise detail page. It also substitutes the
/// installed/custom function name into the usage, examples and sample output so
/// what's shown matches what the user will actually type.

import SwiftUI

/// Renders a ``ShortcutContent`` as one cohesive, lightly-sectioned card.
///
/// - `originalName` / `effectiveName`: when set, any standalone occurrence of the
///   shortcut's default function name in usage/examples/output is rewritten to the
///   name the user chose (or the installed one).
/// - `showsSummaryAndUsage`: set false when the host view already surfaces the
///   summary + usage (e.g. a detail hero) so they aren't duplicated here.
///
/// ```swift
/// ShortcutContentView(content: shortcut.content)
/// ```
struct ShortcutContentView: View {
    let content: ShortcutContent
    var originalName: String = ""
    var effectiveName: String = ""
    var showsSummaryAndUsage: Bool = true

    /// Logical groupings used for internal navigation and list segmentation.
    private enum Section: Hashable { case overview, usage, steps, params, examples, output, notes }

    private var present: [Section] {
        var s: [Section] = []
        if showsSummaryAndUsage, !content.summary.isEmpty { s.append(.overview) }
        if showsSummaryAndUsage, let u = content.usage, !u.isEmpty { s.append(.usage) }
        if !content.whatItDoes.isEmpty { s.append(.steps) }
        if !content.parameters.isEmpty { s.append(.params) }
        if !content.examples.isEmpty { s.append(.examples) }
        if let o = content.sampleOutput, !o.isEmpty { s.append(.output) }
        if !content.notes.isEmpty { s.append(.notes) }
        return s
    }

    var body: some View {
        if !present.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(present.enumerated()), id: \.element) { i, sec in
                    if i > 0 {
                        SectionDivider().padding(.vertical, 16)
                    }
                    sectionView(sec)
                }
            }
            .cardStyle()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    /// - Parameter sec: The segmented grouping mapped to UI hierarchy.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func sectionView(_ sec: Section) -> some View {
        switch sec {
        case .overview:
            labeled("Overview", icon: "text.alignleft") {
                Text(content.summary)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .usage:
            labeled("Usage", icon: "terminal") {
                CommandChip(command: applyingName(content.usage ?? ""))
            }

        case .steps:
            labeled("What it does", icon: "list.bullet") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(content.whatItDoes.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(Color.accentColor.opacity(0.6))
                                .frame(width: 5, height: 5)
                                .padding(.top, 7)
                            Text(step)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

        case .params:
            labeled("Parameters", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(content.parameters) { param in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(param.name)
                                    .font(.caption.monospaced().weight(.semibold))
                                Text(param.required ? "required" : "optional")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule().fill((param.required ? Color.orange : Color.secondary).opacity(0.15))
                                    )
                                    .foregroundColor(param.required ? .orange : .secondary)
                            }
                            Text(param.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

        case .examples:
            labeled("Examples", icon: "sparkles") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(content.examples) { example in
                        VStack(alignment: .leading, spacing: 6) {
                            if !example.description.isEmpty {
                                Text(example.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            CommandChip(command: applyingName(example.command))
                        }
                    }
                }
            }

        case .output:
            labeled("Sample output", icon: "text.and.command.macwindow") {
                Text(applyingName(content.sampleOutput ?? ""))
                    .font(.caption.monospaced())
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .codePanel()
            }

        case .notes:
            labeled("Notes", icon: "lightbulb") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(content.notes.enumerated()), id: \.offset) { _, note in
                        NoteRow(text: note)
                    }
                }
            }
        }
    }

    /// A light sub-section: small labelled header + its content. No per-section card.
    @ViewBuilder
    private func labeled<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content build: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .labelStyle(.matched)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
            build()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Name substitution

    /// Rewrite standalone occurrences of the default function name to the chosen one.
    /// - Parameter s: The literal string representing Apple script definition.
    /// - Returns: A transformed script assigning localized identities.
    private func applyingName(_ s: String) -> String {
        guard !originalName.isEmpty, originalName != effectiveName, !effectiveName.isEmpty else { return s }
        let pattern = "(?<![\\w-])" + NSRegularExpression.escapedPattern(for: originalName) + "(?![\\w-])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(
            in: s, range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: effectiveName)
        )
    }
}

// MARK: - Reusable pieces

/// A monospaced, selectable command line with a copy affordance. No inner scroll.
private struct CommandChip: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            /// Command text sizes to its content so the copy button sits right beside
            /// it (not pushed to the far edge); the Spacer fills the rest of the row.
            ///
            /// **Rationale:** Anchoring the copy button directly to the text ensures visual proximity regardless of the parent window width.
            Text(command)
                .font(.caption.monospaced())
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(copied ? .green : .secondary)
            }
            .appButton(.plain)
            .help("Copy command")

            Spacer(minLength: 0)
        }
        .codePanel()
    }
}

/// A single note line. Picks a leading icon/color from a warning/tip cue if present.
private struct NoteRow: View {
    let text: String

    private var style: (icon: String, color: Color) {
        if text.contains("⚠") || text.localizedCaseInsensitiveContains("warning") || text.localizedCaseInsensitiveContains("important") {
            return ("exclamationmark.triangle.fill", .orange)
        }
        if text.contains("🚫") || text.localizedCaseInsensitiveContains("do not") || text.localizedCaseInsensitiveContains("never") {
            return ("nosign", .red)
        }
        if text.contains("💡") || text.localizedCaseInsensitiveContains("tip") {
            return ("lightbulb.fill", .yellow)
        }
        return ("circle.fill", .secondary)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style.icon)
                .font(style.icon == "circle.fill" ? .system(size: 5) : .caption)
                .foregroundColor(style.color)
                .frame(width: 14, alignment: .center)
                .padding(.top, style.icon == "circle.fill" ? 6 : 2)
            Text(cleaned(text))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Strip a leading cue emoji so it isn't duplicated next to the icon.
    /// - Parameter s: The raw target text block.
    /// - Returns: A simplified string eliminating layout markers.
    private func cleaned(_ s: String) -> String {
        var out = s
        for cue in ["⚠️", "⚠", "🚫", "💡", "🔍"] {
            if out.hasPrefix(cue) { out = String(out.dropFirst(cue.count)) }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
