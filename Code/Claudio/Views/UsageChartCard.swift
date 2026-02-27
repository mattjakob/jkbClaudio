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
        let filtered = readings.filter { $0.timestamp >= start && $0.timestamp <= end }

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
        }
        .padding(14)
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

    private func chartView(filtered: [UsageReading], start: Date, end: Date) -> some View {
        let color = barColor
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
                    y: .value("Usage", value)
                )
                .foregroundStyle(color.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartXScale(domain: start...end)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: range == .sevenDay ? 7 : 6)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        if range == .sevenDay {
                            Text(date, format: .dateTime.weekday(.abbreviated))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(date, format: .dateTime.hour())
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
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
        .chartYScale(domain: 0...100)
        .frame(height: 80)
    }
}
