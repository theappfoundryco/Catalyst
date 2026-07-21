//
//  SelectPythonVersionDropdown.swift
//  Catalyst
//
//  Created by Shivang Gulati on 15/02/26.
//

import SwiftUI

/// A card-styled Python version picker with optional info, warning, and PEP 668 banners.
///
/// Displays a dropdown of available Python installations and contextual banners based on options.
///
/// ## Usage
///
/// ```swift
/// SelectPythonVersionDropdown(
///     selection: $selectedPython,
///     availableVersions: vm.pythonVersions,
///     onSelectionChange: { await vm.reload() }
/// )
/// ```
struct SelectPythonVersionDropdown: View {
    /// Global install-mode preference (drives the 3.12+ override control).
    @ObservedObject private var prefs = InstallPreferences.shared

    /// A mode awaiting confirmation before it becomes active.
    @State private var pendingMode: PipInstallMode?

    /// Binding to the currently selected Python installation.
    @Binding var selection: PythonInstallation?
    
    /// The list of Python installations available on the system.
    let availableVersions: [PythonInstallation]
    
    /// Async callback invoked when the selection changes.
    let onSelectionChange: () async -> Void
    
    /// Optional pip command template, e.g. `"pip install -r requirements.txt"`.
    let installCommandTemplate: String?
    
    /// The system Python version string, used for conflict warnings.
    let systemPythonVersion: String?
    
    /// Callback to check whether a given installation is the system Python.
    let isSystemPython: ((PythonInstallation) -> Bool)?
    
    /// Optional title for a general info banner shown below the picker.
    let infoBannerTitle: String?
    
    /// Optional message for the general info banner.
    let infoBannerMessage: String?
    
    /// Optional array of warning banners shown below the info banner.
    let warningBanners: [(title: String?, message: String)]?
    
    init(
        selection: Binding<PythonInstallation?>,
        availableVersions: [PythonInstallation],
        onSelectionChange: @escaping () async -> Void,
        installCommandTemplate: String? = nil,
        systemPythonVersion: String? = nil,
        isSystemPython: ((PythonInstallation) -> Bool)? = nil,
        infoBannerTitle: String? = nil,
        infoBannerMessage: String? = nil,
        warningBanners: [(title: String?, message: String)]? = nil
    ) {
        self._selection = selection
        self.availableVersions = availableVersions
        self.onSelectionChange = onSelectionChange
        self.installCommandTemplate = installCommandTemplate
        self.systemPythonVersion = systemPythonVersion
        self.isSystemPython = isSystemPython
        self.infoBannerTitle = infoBannerTitle
        self.infoBannerMessage = infoBannerMessage
        self.warningBanners = warningBanners
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select Python Version")
                .font(.headline)
            
            SectionDivider()
            
            Picker("Python Version", selection: $selection) {
                ForEach(availableVersions.sorted { VersionComparator.compare($0.version, $1.version) < 0 }, id: \.version) { python in
                    Text("Python \(python.version)").tag(python as PythonInstallation?)
                }
            }
            // Label hidden (redundant with the "Select Python Version" header) so the menu control
            // fills the full width instead of pinning right with a gap on macOS 26 (Tahoe).
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .onChange(of: selection) { _, _ in
                Task {
                    await onSelectionChange()
                }
            }
            
            if let title = infoBannerTitle, let message = infoBannerMessage {
                BannerView(
                    .info,
                    title: title,
                    message: message,
                    size: .compact
                )
            }
            
            if let warnings = warningBanners {
                ForEach(Array(warnings.enumerated()), id: \.offset) { index, warning in
                    BannerView(
                        .warning,
                        title: warning.title,
                        message: warning.message,
                        size: .compact
                    )
                }
            }
            
            if let selected = selection, let commandTemplate = installCommandTemplate {
                let flags = InstallPreferences.pipFlags(forPythonVersion: selected.version)
                BannerView(
                    .info,
                    title: "Install command",
                    message: "\(selected.path.path) -m \(commandTemplate)" + (flags.isEmpty ? "" : " \(flags)"),
                    size: .compact
                )
            }
            
            if let selected = selection,
               let systemVersion = systemPythonVersion,
               let checker = isSystemPython,
               checker(selected) {
                BannerView(
                    .warning,
                    message: "Caution: Matches System Python (\(systemVersion)). Ensure you are targeting the correct environment.",
                    size: .compact
                )
            }
            
            if let selected = selection,
               VersionComparator.requiresBreakSystemPackages(pythonVersion: selected.version) {
                installModeControl
            }
        }
        .cardStyle()
        .confirmationDialog(
            "Override system integrity?",
            isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }),
            presenting: pendingMode
        ) { mode in
            Button("Enable \(mode.title)", role: .destructive) {
                prefs.mode = mode
                pendingMode = nil
            }
            Button("Cancel", role: .cancel) { pendingMode = nil }
        } message: { mode in
            Text(mode.confirmMessage)
        }
    }

    /// Install-mode picker + dynamic status, shown only for externally-managed
    /// (3.12+) interpreters. Switching away from Protected asks for confirmation.
    private var installModeControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: prefs.mode.icon)
                    .foregroundColor(prefs.mode.tint)
                Text("Install mode")
                    .font(.subheadline.weight(.medium))
                InfoDot(topic: .installModes)

                Spacer()

                Picker("", selection: modeBinding) {
                    ForEach(PipInstallMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            // Exact flag that will be appended to pip — transparent and copyable.
            HStack(spacing: 6) {
                Text("Adds flag")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(prefs.mode.flagDisplay)
                    .font(.caption2.monospaced())
                    .foregroundColor(prefs.mode == .protected ? .secondary : prefs.mode.tint)
                    .textSelection(.enabled)
            }

            BannerView(prefs.mode.statusStyle, message: prefs.mode.statusMessage, size: .compact)
        }
    }

    /// Routes selection changes: turning the override OFF (→ Protected) is safe
    /// and applies immediately; turning it ON stages the choice for confirmation.
    private var modeBinding: Binding<PipInstallMode> {
        Binding(
            get: { prefs.mode },
            set: { newMode in
                if newMode == .protected {
                    prefs.mode = .protected
                } else if newMode != prefs.mode {
                    pendingMode = newMode
                }
            }
        )
    }
}
