import SwiftUI

// MARK: - Grade

/// The single source of truth for turning a 0–100 score into a colour and a word.
///
/// **Rationale:** These thresholds used to be written twice — once here and once inline in
/// `DrCatalystView`'s hand-rolled `Gauge` (`> 80` green, `> 50` orange). The two disagreed, so
/// the *same* score rendered green on Dr. Catalyst and orange on Battery Health. A score of 75
/// was "fair" on one screen and "good" on another. Issue #24. Anything that maps a score to a
/// colour goes through here — never re-inline a threshold.
enum VitalityGrade {
    case excellent
    case fair
    case critical
    case unknown

    /// - Parameter score: A vitality/health score, expected in 0…100.
    init(score: Int) {
        switch score {
        case 90...100: self = .excellent
        case 70..<90:  self = .fair
        case 0..<70:   self = .critical
        default:       self = .unknown
        }
    }

    /// Ring, number and label colour. The only place a score becomes a colour.
    var color: Color {
        switch self {
        case .excellent: return .green
        case .fair:      return .orange
        case .critical:  return .red
        case .unknown:   return .gray
        }
    }

    /// Shown under the number, uppercased by the gauge.
    var label: String {
        switch self {
        case .excellent: return "Excellent"
        case .fair:      return "Fair"
        case .critical:  return "Critical"
        case .unknown:   return "Unknown"
        }
    }
}

// MARK: - Gauge

/// A circular gauge representing an overall vitality score out of 100.
///
/// Deliberately hand-drawn rather than a native `Gauge` + `.accessoryCircularCapacity`: the
/// native accessory styles can't render the grade word beneath the number, and sizing them means
/// `.scaleEffect`, which scales the stroke and leaves the layout bounds unchanged so the gauge
/// silently overlaps its neighbours at narrow widths.
///
/// Size is controlled by the caller; use ``HeroGaugeColumn`` for the standard 100×100 treatment.
///
/// ```swift
/// VitalityGauge(score: 95).frame(width: 100, height: 100)
/// ```
struct VitalityGauge: View {
    /// The value to display, expected in 0…100. Values outside that range render as
    /// ``VitalityGrade/unknown`` (grey) rather than clamping silently.
    let score: Int

    /// Derived, never stored — a stored copy would go stale whenever `score` changed.
    private var grade: VitalityGrade { VitalityGrade(score: score) }

    var body: some View {
        ZStack {
            /// Track
            Circle()
                .stroke(lineWidth: 15)
                .opacity(0.1)
                .foregroundColor(grade.color)

            /// Progress
            Circle()
                /// Clamp the TRIM only, never the score or the grade. `.trim` is undefined outside
                /// 0…1 and an out-of-range score renders as a corrupt ring; the number and the grey
                /// ``VitalityGrade/unknown`` label still report the real value, so a bad score stays
                /// visible rather than being silently flattened to 0 or 100.
                .trim(from: 0.0, to: min(max(CGFloat(score) / 100.0, 0), 1))
                .stroke(style: StrokeStyle(lineWidth: 15, lineCap: .round, lineJoin: .round))
                .foregroundColor(grade.color)
                .rotationEffect(Angle(degrees: 270.0))
                .animation(.linear, value: score)

            VStack {
                Text("\(score)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                Text(grade.label)
                    .font(.caption2.bold())
                    .foregroundColor(grade.color)
                    .textCase(.uppercase)
                    .minimumScaleFactor(0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(score) out of 100, \(grade.label)")
    }
}

// MARK: - Hero stat bar

/// The header strip that opens Dr. Catalyst, Battery Health and SSD Health: a vitality gauge on
/// the left, then divider-separated stat columns filling the rest of the row.
///
/// **Rationale:** All three screens had hand-assembled the identical `HStack` — gauge column,
/// `SectionDivider().frame(height: 100)`, `.frame(maxWidth: .infinity)` on every column, 40pt
/// vertical padding, `controlBackgroundColor`, 12pt corner radius. Drift was inevitable and duly
/// arrived (issue #24): three different gauges, two different `VStack` spacings, and a stale
/// `// Match DrCatalyst size` comment pointing at a size Dr. Catalyst no longer used.
///
/// Columns supply their own leading divider via ``SwiftUI/View/heroColumn()``, which is what lets
/// the trailing content stay an ordinary `@ViewBuilder` — including `if`/`else` branches — rather
/// than a fixed array this component has to interleave separators into.
///
/// ```swift
/// HeroStatBar(title: "Battery Health", score: report.maxCapacityPercent) {
///     StatColumnHeader(label: "Cycle Count", value: "\(report.cycleCount)", subtext: "charge cycles")
///         .heroColumn()
/// }
/// ```
struct HeroStatBar<Columns: View>: View {
    /// Caption above the gauge — the thing being scored ("System Vitality", "Battery Health").
    let title: String
    /// 0–100. Graded by ``VitalityGrade``.
    let score: Int
    @ViewBuilder var columns: () -> Columns

    var body: some View {
        HStack(spacing: 0) {
            HeroGaugeColumn(title: title, score: score)
            columns()
        }
        .padding(.vertical, 40)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
}

/// The gauge half of ``HeroStatBar`` — caption, then a 100×100 ``VitalityGauge``.
///
/// Standalone so a screen that needs the gauge treatment outside the full bar stays consistent
/// with the three that use it.
struct HeroGaugeColumn: View {
    /// Caption above the gauge — the thing being scored ("System Vitality", "Health Score").
    let title: String
    /// 0–100, graded by ``VitalityGrade``.
    let score: Int

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)

            VitalityGauge(score: score)
                .frame(width: 100, height: 100)
        }
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Formats a view as a column of ``HeroStatBar``: a leading divider, then equal-width fill.
    ///
    /// **Gotchas:** The divider belongs to the column, not the bar. Putting separators in the
    /// parent would force the columns to be a countable array, which breaks the moment a caller
    /// needs `if`/`else` (Dr. Catalyst's "Last Scan" does exactly that).
    func heroColumn() -> some View {
        HStack(spacing: 0) {
            SectionDivider()
                .frame(height: 100)
            self
                .frame(maxWidth: .infinity)
        }
    }
}
