import Charts
import SwiftUI

enum ChartRange {
    case sevenDay
    case fiveHour

    var label: String {
        switch self {
        case .sevenDay: "Weekly"
        case .fiveHour: "5-Hour"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .sevenDay: 7 * 86400
        case .fiveHour: 5 * 3600
        }
    }
}

struct UsageChartCard: View {
    let readings: [UsageReading]
    let weeklyUtilization: Double
    let fiveHourUtilization: Double
    let weeklyResetsAt: Date?
    let fiveHourResetsAt: Date?
    @Binding var range: ChartRange

    private var altLabel: String {
        range == .sevenDay ? "5-Hour" : "Weekly"
    }

    private var altUtilization: Double {
        range == .sevenDay ? fiveHourUtilization : weeklyUtilization
    }

    private var altResetsAt: Date? {
        range == .sevenDay ? fiveHourResetsAt : weeklyResetsAt
    }

    private var altPeriodSeconds: TimeInterval {
        range == .sevenDay ? 5 * 3600 : 7 * 86400
    }

    private var currentUtilization: Double {
        range == .sevenDay ? weeklyUtilization : fiveHourUtilization
    }

    private var barColor: Color {
        if currentUtilization >= 80 { return .widgetRed }
        if currentUtilization >= 60 { return .widgetYellow }
        return .white
    }

    private var resetText: String {
        let resetsAt = range == .sevenDay ? weeklyResetsAt : fiveHourResetsAt
        guard let resetsAt else { return "" }
        return "Resets \(formatReset(resetsAt))"
    }

    var body: some View {
        let end = (range == .sevenDay ? weeklyResetsAt : fiveHourResetsAt) ?? Date()
        let start = end.addingTimeInterval(-range.duration)
        let filtered = chartReadings(from: readings, start: start, end: end)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(range.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(currentUtilization))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(barColor)
            }

            if filtered.count >= 2 {
                chartView(filtered: filtered, start: start, end: end)
            } else {
                Text("Collecting usage data...")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 80)
            }

            HStack {
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            UsageBar(
                label: altLabel,
                utilization: altUtilization,
                resetsAt: altResetsAt,
                periodSeconds: altPeriodSeconds
            )
            .padding(.top, 4)
        }
        .padding(14)
        .contentShape(Rectangle())
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                range = range == .sevenDay ? .fiveHour : .sevenDay
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

    private func chartReadings(from readings: [UsageReading], start: Date, end: Date) -> [UsageReading] {
        let filtered = readings.filter { $0.timestamp >= start && $0.timestamp <= end }
        if filtered.count == 1, let only = filtered.first {
            let synthetic = UsageReading(timestamp: start, weekly: only.weekly, fiveHour: only.fiveHour)
            return [synthetic] + filtered
        }
        return filtered
    }

    private func projectionEndValue(filtered: [UsageReading], start: Date, end: Date) -> Double? {
        guard let last = filtered.last, end > last.timestamp else { return nil }
        let lastValue = range == .sevenDay ? last.weekly : last.fiveHour
        let elapsed = last.timestamp.timeIntervalSince(start)
        guard elapsed > min(range.duration * 0.05, 3600) else { return nil }
        let remaining = end.timeIntervalSince(last.timestamp)
        return lastValue + (lastValue / elapsed) * remaining
    }

    private func chartView(filtered: [UsageReading], start: Date, end: Date) -> some View {
        let color = barColor
        let projEnd = projectionEndValue(filtered: filtered, start: start, end: end)
        let projColor: Color = if let projEnd {
            projEnd >= 80 ? .widgetRed : projEnd >= 60 ? .widgetYellow : .white
        } else { .white }

        return Chart {
            ForEach(Array(filtered.enumerated()), id: \.offset) { _, reading in
                let value = range == .sevenDay ? reading.weekly : reading.fiveHour

                AreaMark(
                    x: .value("Time", reading.timestamp),
                    y: .value("Usage", value)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [color.opacity(0.3), color.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Time", reading.timestamp),
                    y: .value("Usage", value),
                    series: .value("S", "actual")
                )
                .foregroundStyle(color.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.catmullRom)
            }

            if let projEnd, let last = filtered.last {
                let lastValue = range == .sevenDay ? last.weekly : last.fiveHour

                LineMark(
                    x: .value("Time", last.timestamp),
                    y: .value("Usage", lastValue),
                    series: .value("S", "proj")
                )
                .foregroundStyle(projColor.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                LineMark(
                    x: .value("Time", end),
                    y: .value("Usage", projEnd),
                    series: .value("S", "proj")
                )
                .foregroundStyle(projColor.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: start...end)
        .chartXAxis {
            if range == .fiveHour {
                let ticks = stride(from: start, through: end, by: 3600).map { $0 }
                AxisMarks(values: ticks) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.hour())
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 7)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.weekday(.abbreviated))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            let yMax = max(projEnd ?? 100, 100)
            let ticks: [Int] = yMax > 100
                ? [0, 50, 100, Int(ceil(yMax / 10) * 10)]
                : [0, 50, 100]
            AxisMarks(values: ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                    .foregroundStyle(.white.opacity(0.1))
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartYScale(domain: 0...max(projEnd ?? 100, 100))
        .frame(height: 80)
    }
}
