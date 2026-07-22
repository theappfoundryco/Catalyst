import SwiftUI

struct VitalityGauge: View {
    let score: Int
    
    var color: Color {
        switch score {
        case 90...100: return .green
        case 70..<90: return .orange
        case 0..<70: return .red
        default: return .gray
        }
    }
    
    var label: String {
        switch score {
        case 90...100: return "Excellent"
        case 70..<90: return "Fair"
        case 0..<70: return "Critical"
        default: return "Unknown"
        }
    }
    
    var body: some View {
        ZStack {
            // Background Circle
            Circle()
                .stroke(lineWidth: 15)
                .opacity(0.1)
                .foregroundColor(color)
            
            // Progress Circle
            Circle()
                .trim(from: 0.0, to: CGFloat(score) / 100.0)
                .stroke(style: StrokeStyle(lineWidth: 15, lineCap: .round, lineJoin: .round))
                .foregroundColor(color)
                .rotationEffect(Angle(degrees: 270.0))
                .animation(.linear, value: score)
            
            VStack {
                Text("\(score)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                Text(label)
                    .font(.caption2.bold())
                    .foregroundColor(color)
                    .textCase(.uppercase)
                    .minimumScaleFactor(0.5)
            }
        }
        // Frame controlled by caller
    }
}

