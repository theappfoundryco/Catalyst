import Foundation
import SwiftUI

/// Defines the supported application distribution models mapped intrinsically through Catalyst logic systems.
enum PackageType: String, CaseIterable, Hashable {
    /// Denotes a Python module managed inside PyPI standards.
    case pip
    /// Denotes a standard Homebrew command-line formula topology.
    case brewFormula
    /// Denotes a GUI macOS distribution configured inside Cask parameters.
    case brewCask
    
    /// Assigns string literals configured explicitly for interface consumption blocks.
    var displayName: String {
        switch self {
        case .pip: return "pip"
        case .brewFormula: return "Homebrew Formula"
        case .brewCask: return "Homebrew Cask"
        }
    }
    
    /// Condenses string formatting generating labels engineered for compact structural boundaries.
    var shortName: String {
        switch self {
        case .pip: return "pip"
        case .brewFormula: return "brew"
        case .brewCask: return "cask"
        }
    }
    
    /// References standard OS graphical descriptors.
    var iconName: String {
        switch self {
        case .pip: return "shippingbox.fill"
        case .brewFormula: return "mug.fill"
        case .brewCask: return "mug.fill"
        }
    }
    
    /// Configures Unicode formatting to embellish terminal diagnostic print commands natively.
    var emoji: String {
        switch self {
        case .pip: return "🐍"
        case .brewFormula: return "🍺"
        case .brewCask: return "🍺"
        }
    }
    
    /// Translates distribution logic directly onto standard system color references.
    var color: Color {
        switch self {
        case .pip: return .blue
        case .brewFormula: return .orange
        case .brewCask: return .green
        }
    }
}
