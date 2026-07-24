import SwiftUI
import Combine
import AppKit

/// Stable support/feedback link routes under `theappfoundry.co/catalyst/*`. Their real
/// destinations live in Vercel Edge Config (dashboard-managed → change with no app update
/// or redeploy); the app only ever points at these fixed URLs. For capture routes we append
/// `version` so the destination (GitHub issue form / Tally form) prefills it. There is no
/// account, so nothing identifying is appended — the reporter types their own contact details
/// into the form if they want a reply.
enum CatalystLink: String, CaseIterable {
    case website, support, feedback, bug, feature, developer

    private static let base = "https://theappfoundry.co/catalyst/"

    var title: String {
        switch self {
        case .website:   return "Website"
        case .support:   return "Email Support"
        case .feedback:  return "Feedback"
        case .bug:       return "Report Bug"
        case .feature:   return "Request Feature"
        case .developer: return "Connect with Developer"
        }
    }

    var icon: String {
        switch self {
        case .website:   return "globe"
        case .support:   return "envelope.fill"
        case .feedback:  return "exclamationmark.bubble.fill"
        case .bug:       return "ladybug.fill"
        case .feature:   return "lightbulb.fill"
        case .developer: return "person.2.fill"
        }
    }

    /// Capture routes (bug/feature/feedback/support) get the version prefill; the marketing
    /// website and the developer profile don't.
    private var prefills: Bool {
        switch self {
        case .website, .developer: return false
        default: return true
        }
    }

    /// The stable URL, with `version` appended for capture routes. The Vercel middleware
    /// forwards these onto the real destination for prefill.
    /// - Parameter version: The major minor semantic version string targeting the changelog.
    /// - Returns: The resolved URL endpoint targeting the GitHub releases page.
    func url(version: String) -> URL? {
        var comps = URLComponents(string: Self.base + rawValue)
        if prefills {
            comps?.queryItems = [URLQueryItem(name: "version", value: version)]
        }
        return comps?.url
    }
}
/// The main About screen providing app version information, changelog highlights, and contact links.
///
/// ```swift
/// AboutView(vm: aboutViewModel)
/// ```
struct AboutView: View {
    @ObservedObject var vm: AboutViewModel
    @State private var isHovering = false
    @State private var showAllHighlights = false
    private let highlightLimit = 6
    
    private var currentYear: String {
        String(Calendar.current.component(.year, from: Date()))
    }
    
    var body: some View {
        // Plain ScrollView (not SmoothPageScroll): About has inline Links, and a
        // link tap inside SmoothPageScroll's single List row can flash the whole
        // page. The screen barely scrolls, so the List engine buys nothing here.
        ScrollView {
            VStack(spacing: 24) {
                // App Icon & Name
                
                VStack {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 128, height: 128)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                    
                    MasterHeaderView(
                        title: vm.appInfo?.appName ?? "Catalyst",
                        subtitle: "Version \(vm.appVersion)",
                        image: "",
                        color: .primary
                    )
                    .padding(.top, -30)
                }
                
                // Version Highlights Card
                if let info = vm.currentVersionInfo {
                    VStack(alignment: .leading, spacing: 16) {
                        // Heading + release tagline on one line: "What's New in X —
                        // <tagline> ✨". The tagline (and sparkle) are accented but the
                        // same size, so it reads as a heading, not a tappable link.
                        Group {
                            if info.tagline.isEmpty {
                                Text("What's New in \(vm.appVersion)")
                            } else {
                                Text("What's New in \(vm.appVersion) — ")
                                    + Text(info.tagline).foregroundColor(.purple)
                                    + Text(" ")
                                    + Text(Image(systemName: "sparkles")).foregroundColor(.purple)
                            }
                        }
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)

                        SectionDivider()
                        
                        // Flattened (was a nested ScrollView — ANTI_PATTERNS.md Rule 1).
                        // Capped at `highlightLimit` with an inline expander so a
                        // long changelog can't blow up the card or the page.
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(showAllHighlights ? info.highlights : Array(info.highlights.prefix(highlightLimit)), id: \.self) { highlight in
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.subheadline)

                                    Text(highlight)
                                        .font(.subheadline)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if info.highlights.count > highlightLimit {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showAllHighlights.toggle()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(showAllHighlights
                                         ? "Show less"
                                         : "Show \(info.highlights.count - highlightLimit) more")
                                    Image(systemName: showAllHighlights ? "chevron.up" : "chevron.down")
                                        .font(.caption2)
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tint)
                            }
                            .appButton(.plain)
                        }

                        if !info.releaseDate.isEmpty {
                            SectionDivider()

                            HStack {
                                Image(systemName: "calendar")
                                    .foregroundColor(.blue)
                                Text("Released: \(info.releaseDate)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .cardStyle()
                }
                
                // Info Card
                VStack(alignment: .leading, spacing: 12) {
                    Text("About")
                        .font(.headline)
                    
                    SectionDivider()
                    
                    InfoRow(icon: "person.fill", label: "Developer", value: vm.appInfo?.developer ?? "The App Foundry")
                    InfoRow(icon: "desktopcomputer", label: "Requires", value: vm.currentVersionInfo?.requirements ?? "macOS 14+")
                    InfoRow(icon: "cpu.fill", label: "Architecture", value: "Universal (Intel + Apple Silicon)")
                    
                    SectionDivider()

                    // Support / feedback links — always available, pointing at the stable
                    // theappfoundry.co/catalyst/* routes (destinations managed in Vercel Edge
                    // Config). Only the version is appended, so bug/feature/feedback forms open
                    // prefilled without Catalyst attaching anything that identifies the reporter.
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 170), spacing: 10)],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        ForEach(CatalystLink.allCases, id: \.self) { link in
                            Button {
                                if let url = link.url(version: vm.appVersion) {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: link.icon)
                                        .frame(width: 18)
                                    Text(link.title)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                    Spacer(minLength: 0)
                                }
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color(NSColor.controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                            }
                            .appButton(.plain)
                        }
                    }
                }
                .cardStyle()
                
                // Copyright
                Text("© \(currentYear) \(vm.appInfo?.copyright ?? "The App Foundry"). All rights reserved.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
            }
            .padding()
        }
        .navigationTitle("About")
        .task {
            await vm.loadAboutInfo()
        }
        .overlay {
            if vm.isLoading {
                ProgressView()
            }
        }
    }

    // The action links point at fixed `/catalyst/<slug>` redirect URLs (repointed via Edge
    // Config, not the app), so they're always available — no longer gated on a fetched about.json.
    private var hasAnyLinks: Bool { true }
}
/// A simple row displaying an icon, a label, and a corresponding value for the About screen.
///
/// ```swift
/// InfoRow(icon: "person.fill", label: "Developer", value: "The App Foundry")
/// ```
struct InfoRow: View {
    let icon: String
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 20)
            
            Text(label)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .fontWeight(.medium)
        }
        .font(.subheadline)
    }
}
