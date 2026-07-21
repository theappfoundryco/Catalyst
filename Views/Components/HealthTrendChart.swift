import SwiftUI
import Charts

struct HealthTrendChart: View {
    let history: [HealthSnapshot]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Health Trend")
                    .font(.headline)
                Text("Last 30 Scans")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 8)
            
            if history.isEmpty {
                ContentUnavailableView("No History", systemImage: "chart.xyaxis.line", description: Text("Run a scan to start tracking health."))
                    .frame(height: 150)
            } else {
                Chart(history) { snapshot in
                    LineMark(
                        x: .value("Date", snapshot.date),
                        y: .value("Score", snapshot.score)
                    )
                    .foregroundStyle(Color.blue.gradient)
                    .interpolationMethod(.catmullRom)
                    
                    AreaMark(
                        x: .value("Date", snapshot.date),
                        y: .value("Score", snapshot.score)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue.opacity(0.3), .blue.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                    
                    if let last = history.last, snapshot.id == last.id {
                        PointMark(
                            x: .value("Date", snapshot.date),
                            y: .value("Score", snapshot.score)
                        )
                        .foregroundStyle(.blue)
                        .annotation(position: .top) {
                            Text("\(last.score)")
                                .font(.caption2.bold())
                                .foregroundColor(.blue)
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 150)
            }
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
}
