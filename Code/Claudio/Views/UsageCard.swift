import SwiftUI

func formatReset(_ date: Date) -> String {
    let seconds = date.timeIntervalSinceNow
    guard seconds > 0 else { return "now" }
    let totalSeconds = Int(seconds)
    let h = totalSeconds / 3600
    let m = (totalSeconds % 3600) / 60
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

private enum PaceStatus {
    case ahead(Int)
    case onPace
    case headroom(Int)
    case unavailable
}

private func computePace(utilization: Double, resetsAt: Date?, periodSeconds: TimeInterval) -> PaceStatus {
    guard let resetsAt, periodSeconds > 0 else { return .unavailable }
    let elapsed = Date().timeIntervalSince(resetsAt.addingTimeInterval(-periodSeconds))
    guard elapsed > periodSeconds * 0.05 else { return .unavailable }
    let expected = min(elapsed / periodSeconds * 100, 100)
    let diff = utilization - expected
    if diff > 5 { return .ahead(Int(diff)) }
    if diff < -5 { return .headroom(Int(-diff)) }
    return .onPace
}

struct UsageBar: View {
    let label: String
    let utilization: Double
    let resetsAt: Date?
    let periodSeconds: TimeInterval

    private var barColor: Color {
        if utilization >= 80 { return .widgetRed }
        if utilization >= 60 { return .widgetYellow }
        return .white
    }

    private var resetText: String {
        guard let resetsAt else { return "—" }
        return formatReset(resetsAt)
    }

    private var pace: PaceStatus {
        computePace(utilization: utilization, resetsAt: resetsAt, periodSeconds: periodSeconds)
    }

    private var paceTooltip: String {
        switch pace {
        case .ahead(let pct): "\(pct)% ahead — consider slowing down"
        case .onPace: "On pace"
        case .headroom(let pct): "\(pct)% headroom — you have capacity"
        case .unavailable: ""
        }
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
                .help(paceTooltip)
        }
    }
}

struct ExtraUsageBar: View {
    let utilization: Double
    let usedDollars: Double
    let limitDollars: Double

    private var barColor: Color {
        if utilization >= 80 { return .widgetRed }
        if utilization >= 60 { return .widgetYellow }
        return .white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Extra Usage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "$%.2f / $%.0f", usedDollars, limitDollars))
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
                        .frame(width: max(0, geo.size.width * min(utilization, 100) / 100), height: 6)
                }
            }
            .frame(height: 6)

            Text("\(Int(utilization))% of monthly limit")
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
    @Binding var chartRange: ChartRange
    let extraUsageEnabled: Bool
    let extraUsageUtilization: Double
    let extraUsageUsedDollars: Double
    let extraUsageLimitDollars: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if chartRange == .sevenDay {
                UsageBar(
                    label: "5-Hour",
                    utilization: fiveHourUtilization,
                    resetsAt: fiveHourResetsAt,
                    periodSeconds: 5 * 3600
                )
            } else {
                UsageBar(
                    label: "Weekly",
                    utilization: weeklyUtilization,
                    resetsAt: weeklyResetsAt,
                    periodSeconds: 7 * 86400
                )
            }

            if extraUsageEnabled {
                ExtraUsageBar(
                    utilization: extraUsageUtilization,
                    usedDollars: extraUsageUsedDollars,
                    limitDollars: extraUsageLimitDollars
                )
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                chartRange = chartRange == .sevenDay ? .fiveHour : .sevenDay
            }
        }
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
