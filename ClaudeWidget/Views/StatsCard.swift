import SwiftUI

struct SparklineView: View {
    let values: [Int]

    var body: some View {
        GeometryReader { geo in
            let maxVal = Double(values.max() ?? 1)
            let step = geo.size.width / Double(max(values.count - 1, 1))

            Path { path in
                for (index, value) in values.enumerated() {
                    let x = Double(index) * step
                    let y = geo.size.height - (Double(value) / maxVal * geo.size.height)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(.white.opacity(0.6), lineWidth: 1.5)
        }
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .monospacedDigit()
        }
    }
}

struct StatsCard: View {
    let stats: WeeklyStats

    private func formatTokens(_ count: Int64) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Week")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            StatRow(label: "Sessions", value: "\(stats.sessions)")
            StatRow(label: "Messages", value: stats.messages.formatted())
            StatRow(label: "Tokens", value: formatTokens(stats.totalTokens))

            if !stats.dailyActivity.isEmpty {
                SparklineView(values: stats.dailyActivity.map(\.messageCount))
                    .frame(height: 30)
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
