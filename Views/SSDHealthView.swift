import SwiftUI

struct SSDHealthView: View {
    @ObservedObject var vm: SSDHealthViewModel
    var onNavigateToDashboard: () -> Void
    @State private var isRefreshing = false
    
    // Grid Columns for Metric Cards (3 columns)
    private let metricColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]
    
    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) { // Consistent 24pt spacing
                
                MasterHeaderView(
                    title: "Disk Vitals",
                    subtitle: "NVMe SSD Health & SMART Diagnostics",
                    image: "internaldrive.fill",
                    color: .blue
                )

                // Non-destructive notice (e.g. a cancelled re-scan). Sits above
                // the content without replacing it, and is dismissible.
                if let notice = vm.scanNotice {
                    HStack(spacing: 8) {
                        BannerView(.warning, message: notice, size: .compact)
                        Button {
                            vm.scanNotice = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                    }
                    .padding(.horizontal)
                    .transition(.opacity)
                }

                // State-driven content
                switch vm.setupState {
                case .checking:
                    ProgressView("Checking prerequisites…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .padding(.horizontal)
                    
                case .brewMissing:
                    SSDSetupCard(
                        icon: "mug",
                        title: "Homebrew Required",
                        message: "Disk Vitals requires Homebrew to install a diagnostic dependency. Please install Homebrew first from the Dashboard.",
                        buttonLabel: "Go to Dashboard",
                        isLoading: false,
                        action: {
                            onNavigateToDashboard()
                        }
                    )
                    .padding(.horizontal)
                    
                case .dependencyMissing:
                    SSDSetupCard(
                        icon: "shippingbox.fill",
                        title: "Diagnostic Dependency Required",
                        message: "A diagnostic tool needs to be installed to read your SSD's health data. This is a one-time setup that takes about 30 seconds.",
                        buttonLabel: "Install Dependency",
                        isLoading: false,
                        action: {
                            Task { await vm.installDependency() }
                        }
                    )
                    .padding(.horizontal)
                    
                case .installing:
                    installingView
                        .padding(.horizontal)
                    
                case .ready, .scanning:
                    if let report = vm.report {
                        reportContent(report)
                    } else {
                        readyToScanView
                            .padding(.horizontal)
                    }
                    
                case .error(let message):
                    errorView(message)
                }
            }
            // Global padding removed to allow banner to manage its own padding vertically/horizontally
            .padding(.vertical)
        }
        .navigationTitle("Disk Vitals")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if vm.setupState == .scanning || isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else if vm.setupState == .ready && vm.report != nil {
                    Button {
                        Task {
                            isRefreshing = true
                            try? await Task.sleep(for: .seconds(1))
                            await vm.scan()
                            isRefreshing = false
                        }
                    } label: {
                        Label("Re-Scan", systemImage: "arrow.clockwise")
                    }
                    .help("Re-scan SSD health")
                }
            }
        }
        .task {
            if vm.setupState == .checking {
                await vm.checkPrerequisites()
            }
        }
    }
    
    // MARK: - Report Content (The Main View)
    
    private func reportContent(_ report: SSDHealthReport) -> some View {
        VStack(spacing: 24) {
            // 1. Tip Banner (AliasView Style - Fixed Width)
            tipBanner

            // 2. Health Status Issues (if any)
            statusIssuesSection(report)
            
            // 4. Dashboard Header (DrCatalyst Style)
            dashboardHero(report)
                .padding(.horizontal)
            
            // 5. Metrics Grid
            LazyVGrid(columns: metricColumns, spacing: 16) {
                // Temperature
                SSDHealthMetricCard(
                    icon: "thermometer.medium",
                    title: "Temperature",
                    value: "\(report.healthMetrics.temperatureCelsius)°C",
                    subtitle: temperatureDescription(report.healthMetrics.temperatureCelsius),
                    color: temperatureColor(report.healthMetrics.temperatureCelsius),
                    gradient: LinearGradient(
                        colors: temperatureGradient(report.healthMetrics.temperatureCelsius),
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                
                // Available Spare
                SSDHealthMetricCard(
                    icon: "battery.100",
                    title: "Available Spare",
                    value: "\(report.healthMetrics.availableSpare)%",
                    subtitle: "Threshold: \(report.healthMetrics.availableSpareThreshold)%",
                    color: spareColor(report.healthMetrics.availableSpare),
                    gradient: LinearGradient(
                        colors: [.green, .mint],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                
                // Percentage Used (Wear)
                SSDHealthMetricCard(
                    icon: "gauge.with.dots.needle.33percent",
                    title: "Wear Level",
                    value: "\(report.healthMetrics.percentageUsed)%",
                    subtitle: wearDescription(report.healthMetrics.percentageUsed),
                    color: wearColor(report.healthMetrics.percentageUsed),
                    gradient: LinearGradient(
                        colors: wearGradient(report.healthMetrics.percentageUsed),
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                
                // Power Cycles
                SSDHealthMetricCard(
                    icon: "power",
                    title: "Power Cycles",
                    value: formatNumber(report.healthMetrics.powerCycles),
                    subtitle: "\(report.healthMetrics.unsafeShutdowns) unsafe shutdowns",
                    color: .blue,
                    gradient: LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                
                // Power On Hours
                SSDHealthMetricCard(
                    icon: "clock.fill",
                    title: "Power On Time",
                    value: formatUptime(report.healthMetrics.powerOnHours),
                    subtitle: "\(formatNumber(report.healthMetrics.powerOnHours)) hours total",
                    color: .indigo,
                    gradient: LinearGradient(
                        colors: [.indigo, .purple],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                
                // Unsafe Shutdowns
                SSDHealthMetricCard(
                    icon: "bolt.slash.fill",
                    title: "Unsafe Shutdowns",
                    value: formatNumber(report.healthMetrics.unsafeShutdowns),
                    subtitle: unsafeShutdownDescription(report.healthMetrics.unsafeShutdowns),
                    color: unsafeShutdownColor(report.healthMetrics.unsafeShutdowns),
                    gradient: LinearGradient(
                        colors: unsafeShutdownGradient(report.healthMetrics.unsafeShutdowns),
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            }
            .padding(.horizontal)

            // 6. Storage Capacity (full-width)
            if let storage = report.storageInfo, storage.totalBytes > 0 {
                StorageVitalsCard(storage: storage)
                    .padding(.horizontal)
            }

            // 7. Data Transfer (Detailed)
            DataTransferBar(transfer: report.dataTransfer)
                .padding(.horizontal)
            
            // 7. Drive Identity (Detailed)
            DriveIdentityCard(info: report.driveInfo)
                .padding(.horizontal)
            
            // 8. Integrity Status (Bottom)
            integritySection(report)
                .padding(.horizontal)
        }
    }
    
    // MARK: - Components
    
    private var tipBanner: some View {
        BannerView(
            .tip,
            message: "Running a scan once a month is recommended to keep track of your disk health."
        )
    }
    
    private func dashboardHero(_ report: SSDHealthReport) -> some View {
        let issues = collectIssues(report)
        // Single pass instead of three separate filter+count passes.
        var criticalCount = 0, warningCount = 0, infoCount = 0
        for issue in issues {
            switch issue.severity {
            case .critical: criticalCount += 1
            case .warning: warningCount += 1
            case .neutral: infoCount += 1 // Using 'neutral' for info/safe
            default: break
            }
        }
        
        return HStack(spacing: 0) {
            // 1. Vitality Gauge + Label
            VStack(spacing: 20) {
                Text("Health Score")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                VitalityGauge(score: report.healthScore)
                    .frame(width: 100, height: 100) // Match DrCatalyst size
            }
            .frame(maxWidth: .infinity)
            
            SectionDivider()
                .frame(height: 100)
            
            // 2. Issues Breakdown
            HStack(spacing: 16) {
                StatBadge_Small(count: criticalCount, label: "Critical", color: .red)
                StatBadge_Small(count: warningCount, label: "Warnings", color: .orange)
                StatBadge_Small(count: infoCount, label: "Info", color: .blue)
            }
            .frame(maxWidth: .infinity)
            
            SectionDivider()
                .frame(height: 100)
            
            // 3. Temperature / Protection
            StatColumnHeader(
                label: "Temperature",
                value: "\(report.healthMetrics.temperatureCelsius)°C",
                subtext: temperatureDescription(report.healthMetrics.temperatureCelsius)
            )
            .frame(maxWidth: .infinity)
            
            SectionDivider()
                .frame(height: 100)
            
            // 4. Last Scan
            StatColumnHeader(
                label: "Last Scan",
                value: report.scanDate.formatted(date: .omitted, time: .shortened),
                subtext: report.scanDate.formatted(date: .abbreviated, time: .omitted)
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 40) // Match DrCatalyst padding
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
    
    @ViewBuilder
    private func statusIssuesSection(_ report: SSDHealthReport) -> some View {
        let issues = collectIssues(report)
        if !issues.isEmpty {
            VStack(spacing: 12) {
                ForEach(issues.filter { $0.severity != .neutral }, id: \.message) { issue in
                    BannerView(
                        issue.severity == .critical ? .critical : .warning,
                        message: issue.message,
                    )
                }
            }
        }
    }
    
    private struct Issue {
        let message: String
        let severity: SSDStatusBadge.BadgeStatus
    }
    
    private func collectIssues(_ report: SSDHealthReport) -> [Issue] {
        var issues: [Issue] = []
        
        if report.overallHealth != "PASSED" {
            issues.append(Issue(message: "SMART status indicates imminent failure (\(report.overallHealth)). Back up your data immediately and replace the drive.", severity: .critical))
        }
        
        if report.healthMetrics.percentageUsed > 50 {
            issues.append(Issue(message: "Drive wear level is high (\(report.healthMetrics.percentageUsed)% used). The SSD is approaching its rated endurance limit. Monitor closely.", severity: .warning))
        }
        
        // Only warn if spare is genuinely low (< 50%) AND close to threshold
        // This prevents false positives on drives with high thresholds (e.g., 99%)
        if report.healthMetrics.availableSpare < 50 && report.healthMetrics.availableSpare <= report.healthMetrics.availableSpareThreshold + 10 {
            issues.append(Issue(message: "Spare capacity critically low (\(report.healthMetrics.availableSpare)%). The drive is running out of reserve blocks to replace bad sectors. Consider replacing the drive soon.", severity: .warning))
        }
        
        if report.healthMetrics.temperatureCelsius > 60 {
            issues.append(Issue(message: "Drive running hot (\(report.healthMetrics.temperatureCelsius)°C). Prolonged heat can reduce lifespan. Check your system's cooling and airflow.", severity: .warning))
        }
        
        if report.healthMetrics.unsafeShutdowns > 30 {
            issues.append(Issue(message: "High number of unsafe shutdowns detected (\(report.healthMetrics.unsafeShutdowns)). Sudden power loss can cause data corruption. Ensure your power supply is stable.", severity: .warning))
        }
        
        // Add an info item if everything is perfect, or just return empty
        if issues.isEmpty {
             issues.append(Issue(message: "No issues detected. Your drive is operating within normal parameters.", severity: .neutral))
        }
        
        return issues
    }
    
    private func integritySection(_ report: SSDHealthReport) -> some View {
        HStack {
            Image(systemName: "shield.checkered")
                .foregroundColor(.green)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Integrity Check")
                    .font(.headline)
                if report.errorInfo.mediaErrors == 0 && !report.errorInfo.hasCriticalWarning {
                    Text("No media or data integrity errors found.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Issues detected. Check SMART log.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            Spacer()
            
            if report.errorInfo.mediaErrors == 0 {
                Text("PASSED")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .foregroundColor(.green)
                    .cornerRadius(4)
            } else {
                Text("ISSUES")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1))
                    .foregroundColor(.orange)
                    .cornerRadius(4)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
    
    // MARK: - Ready to Scan View
    
    private var readyToScanView: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(colors: [.green, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            
            Text("Ready to Scan")
                .font(.title2.bold())
            
            Text("Analyze your SSD's health, temperature, wear level, and lifetime statistics.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                Task { await vm.scan() }
            } label: {
                HStack {
                    Image(systemName: "heart.text.square.fill")
                    Text("Scan Your Disk")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            Text("You will be prompted for your admin password")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(60)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
    }

    // MARK: - Installing View (Same as before)
    private var installingView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Installing dependency...").font(.headline)
        }.padding(40).frame(maxWidth: .infinity)
    }
    
    // MARK: - Error View
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundColor(.orange)
            Text("Scan Error").font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Retry") { Task { await vm.checkPrerequisites() } }.buttonStyle(.bordered)
        }
        // Match the framing of the other states (Ready-to-Scan) so the error
        // reads as a proper centered card, not a cramped floating cluster.
        .padding(60)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .padding(.horizontal)
    }

    // MARK: - Helpers (Same as before)
    private func temperatureColor(_ temp: Int) -> Color { temp > 70 ? .red : (temp > 60 ? .orange : .green) }
    private func temperatureGradient(_ temp: Int) -> [Color] { temp > 70 ? [.red, .orange] : (temp > 60 ? [.orange, .yellow] : [.green, .mint]) }
    private func temperatureDescription(_ temp: Int) -> String { temp > 70 ? "Running Hot" : (temp > 60 ? "Warm" : "Normal") }
    private func spareColor(_ spare: Int) -> Color { spare < 50 ? .red : (spare < 90 ? .orange : .green) }
    private func wearColor(_ used: Int) -> Color { used > 50 ? .red : (used > 10 ? .orange : .green) }
    private func wearGradient(_ used: Int) -> [Color] { used > 50 ? [.red, .orange] : (used > 10 ? [.orange, .yellow] : [.green, .cyan]) }
    private func wearDescription(_ used: Int) -> String { used > 80 ? "End of Life Near" : (used > 50 ? "Significant Wear" : (used > 10 ? "Normal Wear" : "Like New")) }
    private func unsafeShutdownColor(_ count: Int) -> Color { count > 30 ? .orange : .green }
    private func unsafeShutdownGradient(_ count: Int) -> [Color] { count > 30 ? [.orange, .red] : [.green, .mint] }
    private func unsafeShutdownDescription(_ count: Int) -> String { count > 30 ? "High" : (count > 10 ? "Moderate" : "Low") }
    private func formatNumber(_ n: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }
    private func formatUptime(_ hours: Int) -> String {
        let days = hours / 24
        let remainingHours = hours % 24
        return days > 0 ? "\(days)d \(remainingHours)h" : "\(hours)h"
    }
}
