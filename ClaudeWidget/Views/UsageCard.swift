import SwiftUI

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
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: resetsAt, relativeTo: .now)
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

            HStack {
                Text("Resets")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct UsageCard: View {
    let fiveHourUtilization: Double
    let fiveHourResetsAt: Date?
    let weeklyUtilization: Double
    let weeklyResetsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            UsageBar(
                label: "5-Hour",
                utilization: fiveHourUtilization,
                resetsAt: fiveHourResetsAt
            )

            UsageBar(
                label: "Weekly",
                utilization: weeklyUtilization,
                resetsAt: weeklyResetsAt
            )
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
