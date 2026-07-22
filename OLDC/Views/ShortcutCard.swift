import SwiftUI

struct ShortcutCard: View {
    let shortcut: ShortcutItem
    let isInstalled: Bool
    let customName: String?
    
    // Solid accent instead of a LinearGradient. Gradients used as a fill on TEXT/SF Symbols force
    // per-frame offscreen rasterization, which made the LazyVGrid stutter while scrolling. A solid
    // color renders cheaply and reads nearly identically.
    var accent: Color {
        switch shortcut.color {
        case "orange": return .orange
        case "blue":   return .blue
        case "purple": return .purple
        case "green":  return .green
        case "red":    return .red
        case "yellow": return .yellow
        case "cyan":   return .cyan
        default:       return .gray
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top section with icon and category
            HStack {
                Image(systemName: shortcut.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 50, height: 50)
                    .background(
                        Circle()
                            .fill(accent.opacity(0.15))
                    )
                
                Spacer()
                
                // Category badge
                Text(shortcut.category)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(accent.opacity(0.2))
                    )
                    .foregroundStyle(accent)
            }
            .padding(16)
            
            // Title and tagline
            VStack(alignment: .leading, spacing: 6) {
                Text(shortcut.title)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                
                Text(shortcut.tagline)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            
            SectionDivider()
            
            // Bottom section with status
            HStack(spacing: 8) {
                if isInstalled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    
                    if let name = customName {
                        Text("Installed as \(name)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Installed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.blue)
                        .font(.caption)
                    
                    Text("Tap to install")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
        .background(Color(NSColor.controlBackgroundColor))
        // Clip the whole card (including the bottom section's square-cornered
        // fill) to the rounded shape — otherwise those square corners poke past
        // the rounded card and read as a shadow/artifact at the bottom corners.
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.1), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
