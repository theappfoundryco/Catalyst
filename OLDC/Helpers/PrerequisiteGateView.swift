//
//  PrerequisiteGateView.swift
//  Catalyst
//
//  Full-view replacement when a prerequisite tool is not installed.
//  Cosmetics match SSDSetupCard exactly.
//
import SwiftUI

/// A full-view gate card shown when a prerequisite tool (Homebrew, Python) is not installed.
///
/// Replaces the **entire** view content below the header — no banners, pickers, or
/// buttons leak through. Used with a simple `if/else` at the view level.
///
/// ## Usage
///
/// ```swift
/// MasterHeaderView(...)
///
/// if vm.isBrewInstalled {
///     // all view content
/// } else {
///     PrerequisiteGateView.brewMissing()
/// }
/// ```
struct PrerequisiteGateView: View {
    /// SF Symbol name for the icon.
    let icon: String
    
    /// Bold headline, e.g. "Homebrew Not Installed".
    let title: String
    
    /// Secondary description text.
    let message: String
    
    /// Gradient colors for the icon.
    let gradient: [Color]
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            
            Text(title)
                .font(.title2.bold())
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }
    
    /// Homebrew not installed preset.
    static func brewMissing() -> PrerequisiteGateView {
        PrerequisiteGateView(
            icon: "mug",
            title: "Homebrew Not Installed",
            message: "Install Homebrew from the Dashboard to use this feature.",
            gradient: [.orange, .red]
        )
    }
    
    /// Python with pip not available preset.
    static func pythonMissing() -> PrerequisiteGateView {
        PrerequisiteGateView(
            icon: "shippingbox",
            title: "Python with pip Not Available",
            message: "Install Python from the Dashboard to use this feature.",
            gradient: [.blue, .purple]
        )
    }
}
