import SwiftUI

struct BatteryHealthView: View {
    @ObservedObject var vm: BatteryHealthViewModel

    private let metricColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                MasterHeaderView(
                    title: "Battery Health",
                    subtitle: "Capacity, Cycles & Condition",
                    image: "battery.100.bolt",
                    color: .green
                )

                switch vm.state {
                case .idle, .scanning where vm.report == nil:
                    scanningView
                default:
                    if let report = vm.report {
                        if report.hasBattery {
                            reportContent(report)
                        } else {
                            noBatteryView
                        }
                    } else {
                        scanningView
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Battery Health")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if vm.state == .scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await vm.scan() } } label: {
                        Label("Re-Scan", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .task { if vm.state == .idle { await vm.scan() } }
    }

    // MARK: - Report

    @ViewBuilder
    private func reportContent(_ report: BatteryReport) -> some View {
        VStack(spacing: 24) {
            hero(report).padding(.horizontal)

            LazyVGrid(columns: metricColumns, spacing: 16) {
                SSDHealthMetricCard(
                    icon: "bolt.heart.fill",
                    title: "Charge",
                    value: "\(report.chargePercent)%",
                    subtitle: report.isCharging ? "Charging" : (report.powerSource == "AC Power" ? "On AC" : "On Battery"),
                    color: chargeColor(report.chargePercent),
                    gradient: gradient(chargeColor(report.chargePercent))
                )

                SSDHealthMetricCard(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Cycle Count",
                    value: "\(report.cycleCount)",
                    subtitle: cycleSubtitle(report.cycleCount),
                    color: cycleColor(report.cycleCount),
                    gradient: gradient(cycleColor(report.cycleCount))
                )

                SSDHealthMetricCard(
                    icon: report.condition == "Normal" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    title: "Condition",
                    value: report.condition,
                    subtitle: report.condition == "Normal" ? "Healthy" : "Consider servicing",
                    color: report.condition == "Normal" ? .green : .orange,
                    gradient: gradient(report.condition == "Normal" ? .green : .orange)
                )

                if let temp = report.temperatureCelsius {
                    SSDHealthMetricCard(
                        icon: "thermometer.medium",
                        title: "Temperature",
                        value: String(format: "%.0f°C", temp),
                        subtitle: temp > 40 ? "Warm" : "Normal",
                        color: temp > 40 ? .orange : .green,
                        gradient: gradient(temp > 40 ? .orange : .green)
                    )
                }

                if let full = report.fullChargeCapacitymAh {
                    SSDHealthMetricCard(
                        icon: "battery.100",
                        title: "Full Charge",
                        value: "\(full) mAh",
                        subtitle: report.designCapacitymAh.map { "Design: \($0) mAh" } ?? "Current capacity",
                        color: .blue,
                        gradient: gradient(.blue)
                    )
                }

                if let time = report.timeRemaining {
                    SSDHealthMetricCard(
                        icon: "clock.fill",
                        title: report.isCharging ? "Time to Full" : "Time Left",
                        value: time,
                        subtitle: report.powerSource,
                        color: .indigo,
                        gradient: gradient(.indigo)
                    )
                }
            }
            .padding(.horizontal)
        }
    }

    private func hero(_ report: BatteryReport) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 16) {
                Text("Battery Health")
                    .font(.headline).foregroundColor(.secondary)
                VitalityGauge(score: report.maxCapacityPercent)
                    .frame(width: 100, height: 100)
            }
            .frame(maxWidth: .infinity)

            SectionDivider().frame(height: 100)

            StatColumnHeader(
                label: "Maximum Capacity",
                value: "\(report.maxCapacityPercent)%",
                subtext: "of design capacity"
            )
            .frame(maxWidth: .infinity)

            SectionDivider().frame(height: 100)

            StatColumnHeader(
                label: "Cycle Count",
                value: "\(report.cycleCount)",
                subtext: "charge cycles"
            )
            .frame(maxWidth: .infinity)

            SectionDivider().frame(height: 100)

            StatColumnHeader(
                label: "Condition",
                value: report.condition,
                subtext: report.powerSource
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 40)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    // MARK: - States

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Reading battery telemetry…").font(.headline)
        }.padding(40).frame(maxWidth: .infinity).padding(.horizontal)
    }

    private var noBatteryView: some View {
        VStack(spacing: 16) {
            Image(systemName: "powerplug.fill")
                .font(.system(size: 56))
                .foregroundStyle(LinearGradient(colors: [.gray, .secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("No Internal Battery").font(.title2.bold())
            Text("This Mac runs on AC power and has no battery to report on.")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .padding(60).frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor)).cornerRadius(16)
        .padding(.horizontal)
    }

    // MARK: - Helpers

    private func gradient(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color, color.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private func chargeColor(_ p: Int) -> Color { p < 20 ? .red : (p < 50 ? .orange : .green) }
    private func cycleColor(_ c: Int) -> Color { c > 1000 ? .red : (c > 800 ? .orange : .green) }
    private func cycleSubtitle(_ c: Int) -> String {
        // Apple rates most modern notebooks for ~1000 cycles.
        let remaining = max(0, 1000 - c)
        return "~\(remaining) of 1000 left"
    }
}
