import SwiftUI

struct StorageDNAView: View {
    let report: StorageReport
    
    // Gradient for the "Heat Sensitive" bar
    // Transitions: Blue (Code) -> Orange (Brew) -> Red (Junk/Cache)
    // But since we have segments, each segment has color.
    // The "Heat" is the overall pressure (how full is the disk).
    
    var pressureColor: Color {
        if report.percentUsed > 0.9 { return .red }
        if report.percentUsed > 0.8 { return .orange }
        return .green
    }
    
    // Use String for ID to handle both UUIDs and static "system"/"free" keys
    @State private var hoveredID: String? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage Matrix")
                        .font(.headline)
                    Text("Developer Footprint Analyzer")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Total / Free
                HStack(spacing: 16) {
                    StatPair(label: "Used", value: ByteCountFormatter.string(fromByteCount: report.usedSize, countStyle: .file))
                    StatPair(label: "Free", value: ByteCountFormatter.string(fromByteCount: report.freeSize, countStyle: .file))
                }
            }
            
            // The "DNA" Bar
            GeometryReader { geo in
                HStack(spacing: 2) { // 2px gap per segment for "DNA" look
                    // 1. Calculate specific category widths
                    ForEach(report.categories) { category in
                        if category.bytes > 0 {
                            Rectangle()
                                .fill(Color(hex: category.colorHex))
                                .frame(width: width(for: category.bytes, total: report.totalSize, in: geo.size.width))
                                .overlay(
                                    Rectangle() // Gloss effect
                                        .fill(LinearGradient(colors: [.white.opacity(0.1), .clear], startPoint: .top, endPoint: .bottom))
                                )
                                .opacity(hoveredID == category.id.uuidString ? 1.0 : (hoveredID == nil ? 1.0 : 0.4))
                                .animation(.easeInOut(duration: 0.12), value: hoveredID)
                                .onHover { isHovering in
                                    hoveredID = isHovering ? category.id.uuidString : nil
                                }
                        }
                    }
                    
                    // 2. The "System/Other" (Remaining Used)
                    let accountedFor = report.categories.reduce(0) { $0 + $1.bytes }
                    let otherUsed = report.usedSize - accountedFor
                    if otherUsed > 0 {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: width(for: otherUsed, total: report.totalSize, in: geo.size.width))
                            .opacity(hoveredID == "system" ? 1.0 : (hoveredID == nil ? 1.0 : 0.4))
                            .animation(.easeInOut(duration: 0.12), value: hoveredID)
                            .onHover { isHovering in
                                hoveredID = isHovering ? "system" : nil
                            }
                    }
                    
                    // 3. Free Space
                    Rectangle()
                        .fill(Color.green) // Standard Green
                        .frame(width: width(for: report.freeSize, total: report.totalSize, in: geo.size.width))
                        .opacity(hoveredID == "free" ? 1.0 : (hoveredID == nil ? 1.0 : 0.4))
                        .animation(.easeInOut(duration: 0.12), value: hoveredID)
                        .onHover { isHovering in
                            hoveredID = isHovering ? "free" : nil
                        }
                }
                .cornerRadius(4)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 24)
            .padding(.vertical, 8)
            
            // Legend / Key (Horizontal Scrollable if many)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(report.categories) { category in
                        if category.bytes > 0 {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(hex: category.colorHex))
                                    .frame(width: 8, height: 8)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.name)
                                        .font(.caption2.bold())
                                        .foregroundColor(.primary)
                                    Text(ByteCountFormatter.string(fromByteCount: category.bytes, countStyle: .file))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(8)
                            .background(hoveredID == category.id.uuidString ? Color.white.opacity(0.1) : Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                            .animation(.easeInOut(duration: 0.12), value: hoveredID)
                            .onHover { isHovering in
                                hoveredID = isHovering ? category.id.uuidString : nil
                            }
                        }
                    }
                    
                    // "System" Legend
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.gray.opacity(0.5))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("System / User")
                                .font(.caption2.bold())
                            Text("Other files")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                    .background(hoveredID == "system" ? Color.white.opacity(0.1) : Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .animation(.easeInOut(duration: 0.12), value: hoveredID)
                    .onHover { isHovering in
                        hoveredID = isHovering ? "system" : nil
                    }
                    
                    // "Free" Legend
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Free Space")
                                .font(.caption2.bold())
                            Text("Available")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                    .background(hoveredID == "free" ? Color.white.opacity(0.1) : Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .animation(.easeInOut(duration: 0.12), value: hoveredID)
                    .onHover { isHovering in
                        hoveredID = isHovering ? "free" : nil
                    }
                }
                .padding(.horizontal, 1) // Avoid clipping shadow
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
    
    func width(for bytes: Int64, total: Int64, in availableWidth: CGFloat) -> CGFloat {
        let fraction = Double(bytes) / Double(total)
        return max(0, availableWidth * fraction)
    }
}

struct StatPair: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
                .bold()
        }
    }
}

// Helper for Hex Color
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
