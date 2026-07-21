import SwiftUI

struct IssueGroup: View {
    let title: String
    let color: Color
    let issues: [HealthIssue]
    let onFix: (HealthIssue) async -> Void
    
    @State private var isExpanded = true
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                ForEach(issues) { issue in
                    IssueCard(issue: issue) {
                         Task { await onFix(issue) }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                
                Text(title)
                    .font(.headline)
                
                Spacer()
                
                Text("\(issues.count)")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(color.opacity(0.1))
                    .foregroundColor(color)
                    .cornerRadius(12)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
}
