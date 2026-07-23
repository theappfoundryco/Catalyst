import SwiftUI

// MARK: - SSD Metric Gauge (Mini circular gauge for individual metrics)
/// A mini circular gauge visualizing a single SSD metric, such as temperature or lifespan used.
///
/// ```swift
/// SSDMetricGauge(value: 45, maxValue: 100, unit: "°C", color: .orange)
/// ```
struct SSDMetricGauge: View {
    let value: Int
    let maxValue: Int
    let unit: String
    let color: Color
    
    private var progress: Double {
        guard maxValue > 0 else { return 0 }
        return min(Double(value) / Double(maxValue), 1.0)
    }
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: 8)
                .opacity(0.1)
                .foregroundColor(color)
            
            Circle()
                .trim(from: 0.0, to: progress)
                .stroke(style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .foregroundColor(color)
                .rotationEffect(Angle(degrees: 270.0))
                .animation(.easeInOut(duration: 0.6), value: progress)
            
            VStack(spacing: 2) {
                Text("\(value)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text(unit)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 56, height: 56)
    }
}

// MARK: - SSD Health Metric Card
/// A styled card presenting a high-level SSD health metric with an icon and gradient.
///
/// ```swift
/// SSDHealthMetricCard(icon: "thermometer", title: "Temperature", value: "45°C", subtitle: "Normal", color: .orange, gradient: myGradient)
/// ```
struct SSDHealthMetricCard: View {
    let icon: String
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    let gradient: LinearGradient
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    Circle()
                        .fill(gradient.opacity(0.1))
                        .frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .foregroundStyle(gradient)
                        .font(.system(size: 18, weight: .semibold))
                }
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(gradient)
                .padding(.top, 4)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .rasterizedCard()
    }
}

// MARK: - SSD Status Badge
/// A badge indicating the overall status of an SSD metric (passed, warning, critical, neutral).
///
/// ```swift
/// SSDStatusBadge(label: "SMART Status", status: .passed)
/// ```
struct SSDStatusBadge: View {
    let label: String
    let status: BadgeStatus
    
    /// Differentiates warning severity levels for hardware threshold violations.
    enum BadgeStatus {
        case passed, warning, critical, neutral
        
        var color: Color {
            switch self {
            case .passed: return .green
            case .warning: return .orange
            case .critical: return .red
            case .neutral: return .blue
            }
        }
        
        var icon: String {
            switch self {
            case .passed: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .critical: return "xmark.octagon.fill"
            case .neutral: return "info.circle.fill"
            }
        }
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.icon)
                .foregroundColor(status.color)
                .font(.system(size: 14))
            
            Text(label)
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.medium)
            
            Spacer()
            
            Text(status == .passed ? "OK" : status == .warning ? "Warning" : "Critical")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(status.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(status.color.opacity(0.12))
                .cornerRadius(6)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}
/// A card detailing the hardware specifications and firmware of the active SSD.
///
/// ```swift
/// DriveIdentityCard(info: driveInfo)
/// ```
struct DriveIdentityCard: View {
    let info: DriveInfo
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drive Identity")
                        .font(.headline)
                    Text("Hardware Specification & Firmware")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "internaldrive.fill")
                    .font(.title2)
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
            
            // Symmetrical Grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                IdentityItem(label: "Model Number", value: info.modelNumber, icon: "cpu")
                IdentityItem(label: "Serial Number", value: info.maskedSerial, icon: "barcode")
                IdentityItem(label: "Firmware", value: info.firmwareVersion, icon: "memorychip")
                IdentityItem(label: "Protocol", value: info.nvmeVersion, icon: "network")
                IdentityItem(label: "Namespaces", value: "\(info.numberOfNamespaces)", icon: "square.stack.3d.up")
                IdentityItem(label: "PCI Vendor", value: info.pciVendorID, icon: "tag.fill")
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

/// Displays a foundational hardware identification property.
struct IdentityItem: View {
    let label: String
    let value: String
    let icon: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fontWeight(.medium)
                Text(value)
                    .font(.subheadline) // Removed monospaced design for cleaner look, or keep if preferred
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .allowsTightening(true)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5)) // Inner contrast
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.05), lineWidth: 1)
        )
    }
}

// MARK: - Storage Vitals Card (full-width capacity overview)
/// A full-width card providing a detailed breakdown of the boot volume's storage capacity.
///
/// ```swift
/// StorageVitalsCard(storage: storageInfo)
/// ```
struct StorageVitalsCard: View {
    let storage: StorageInfo

    private var usedColor: Color {
        switch storage.fractionUsed {
        case ..<0.75: return .blue
        case ..<0.90: return .orange
        default: return .red
        }
    }

    /// Formats a raw 64-bit byte count into a localized human-readable string.
    /// - Parameter value: The raw capacity calculated in basic structural bytes.
    /// - Returns: A localized formatted string converted to human units.
    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage Capacity")
                        .font(.headline)
                    Text("Boot Volume Usage")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if storage.nvmCapacityFormatted != "Unknown" {
                    HStack(spacing: 6) {
                        Text("Drive")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(storage.nvmCapacityFormatted)
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                }
                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(
                        LinearGradient(colors: [usedColor, usedColor.opacity(0.6)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }

            // Big headline: used of total
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bytes(storage.usedBytes))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Text("used of \(bytes(storage.totalBytes))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int((storage.fractionUsed * 100).rounded()))%")
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(usedColor)
            }

            // Usage bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [usedColor, usedColor.opacity(0.7)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geo.size.width * storage.fractionUsed, 6))
                        .animation(.easeInOut(duration: 0.6), value: storage.fractionUsed)
                }
            }
            .frame(height: 14)

            // Legend — three columns split by vertical rules, mirroring the
            // Lifetime I/O card. Coloured dot + label above the value.
            HStack(spacing: 0) {
                StorageLegendItem(label: "Used", value: bytes(storage.usedBytes), color: usedColor)
                    .frame(maxWidth: .infinity)
                VerticalRule()
                    .padding(.horizontal, 20)
                StorageLegendItem(label: "Free", value: bytes(storage.freeBytes), color: .green)
                    .frame(maxWidth: .infinity)
                VerticalRule()
                    .padding(.horizontal, 20)
                StorageLegendItem(label: "Total", value: bytes(storage.totalBytes), color: .secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

/// A graphical legend component explaining disk utilization coloring.
private struct StorageLegendItem: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fontWeight(.medium)
                Text(value)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.semibold)
            }
        }
    }
}

// MARK: - Data Transfer Bar
/// A card visualizing the lifetime data transfer and I/O command statistics for the SSD.
///
/// ```swift
/// DataTransferBar(transfer: transferStats)
/// ```
struct DataTransferBar: View {
    let transfer: DataTransfer
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lifetime I/O Stats")
                        .font(.headline)
                    Text("Data & Command Throughput")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // R/W Ratio Badge
                HStack(spacing: 6) {
                    Text("R/W Ratio")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.2f", transfer.readWriteRatio))
                        .font(.caption.bold())
                        .foregroundColor(transfer.readWriteRatio > 100 ? .orange : .primary) // Highlight extreme usage
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }
            
            // Visual Bar
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle()
                        .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geo.size.width * transfer.readFraction - 1, 4))
                    
                    Rectangle()
                        .fill(LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geo.size.width * (1 - transfer.readFraction) - 1, 4))
                }
                .cornerRadius(6)
            }
            .frame(height: 24)
            .padding(.vertical, 4)
            
            // Detailed Stat Grid
            HStack(spacing: 0) {
                // Reads
                VStack(alignment: .leading, spacing: 12) {
                    StatDetailRow(
                        label: "Data Read",
                        value: transfer.dataReadFormatted,
                        icon: "arrow.down.circle.fill",
                        color: .blue
                    )
                    SectionDivider()
                    StatDetailRow(
                        label: "Read Commands",
                        value: formatLargeNumber(transfer.hostReadCommands),
                        icon: "doc.text.fill",
                        color: .blue.opacity(0.7)
                    )
                }
                .frame(maxWidth: .infinity)

                // Vertical centre line the horizontal rules stretch up to.
                VerticalRule()
                    .padding(.horizontal, 20)

                // Writes — pushed toward the trailing edge, but kept internally
                // leading-aligned so both icons line up vertically. Slight trailing
                // padding shifts the block a touch left for visual balance.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 12) {
                        StatDetailRow(
                            label: "Data Written",
                            value: transfer.dataWrittenFormatted,
                            icon: "arrow.up.circle.fill",
                            color: .orange
                        )
                        SectionDivider()
                        StatDetailRow(
                            label: "Write Commands",
                            value: formatLargeNumber(transfer.hostWriteCommands),
                            icon: "pencil.circle.fill",
                            color: .orange.opacity(0.7)
                        )
                    }
                    .padding(.trailing, 12)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
    
    /// Inserts standardized grouping separators into raw SMART counter values.
    /// - Parameter n: The raw mathematical scalar.
    /// - Returns: A string localized with appropriate digit grouping.
    private func formatLargeNumber(_ n: Int64) -> String {
        let number = Double(n)
        if number >= 1_000_000_000 {
            return String(format: "%.2fB", number / 1_000_000_000)
        } else if number >= 1_000_000 {
            return String(format: "%.2fM", number / 1_000_000)
        } else if number >= 1_000 {
            return String(format: "%.2fK", number / 1_000)
        }
        return "\(n)"
    }
}

/// Renders a singular SMART controller metric alongside its numeric value.
struct StatDetailRow: View {
    let label: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fontWeight(.medium)
                Text(value)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.semibold)
            }
        }
    }
}



// MARK: - Setup Card (Dependency/Brew missing)
/// A card shown when prerequisite tools for SSD scanning are missing or need setup.
///
/// ```swift
/// SSDSetupCard(icon: "hammer", title: "Setup Required", message: "...", buttonLabel: "Install", isLoading: false) { setup() }
/// ```
struct SSDSetupCard: View {
    let icon: String
    let title: String
    let message: String
    let buttonLabel: String
    let isLoading: Bool
    let action: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            
            Text(title)
                .font(.title2.bold())
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            
            Button(action: action) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(buttonLabel)
                }
            }
            .appButton(.primary)
            .controlSize(.large)
            .disabled(isLoading)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }
}
