import SwiftUI

func formatReset(_ date: Date) -> String {
    let seconds = date.timeIntervalSinceNow
    guard seconds > 0 else { return "now" }
    if seconds < 48 * 3600 {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h >= 24 {
            let d = h / 24
            let rh = h % 24
            return "in \(d)d \(rh)h"
        }
        if h > 0 {
            return "in \(h)h \(m)m"
        }
        return "in \(m)m"
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: .now)
}

struct UsageBar: View {
    let label: String
    let utilization: Double
    let resetsAt: Date?

    private var barColor: Color {
        if utilization >= 80 { return .red }
        if utilization >= 60 { return .yellow }
        return .white
    }

    private var resetText: String {
        guard let resetsAt else { return "—" }
        return formatReset(resetsAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(utilization))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(barColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.1))
                        .frame(height: 6)

                    Capsule()
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * utilization / 100), height: 6)
                }
            }
            .frame(height: 6)

            Text("Resets \(resetText)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct UsageCard: View {
    let fiveHourUtilization: Double
    let fiveHourResetsAt: Date?
    let weeklyUtilization: Double
    let weeklyResetsAt: Date?
    let chartRange: ChartRange

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if chartRange == .sevenDay {
                UsageBar(
                    label: "5-Hour",
                    utilization: fiveHourUtilization,
                    resetsAt: fiveHourResetsAt
                )
            } else {
                UsageBar(
                    label: "Weekly",
                    utilization: weeklyUtilization,
                    resetsAt: weeklyResetsAt
                )
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
