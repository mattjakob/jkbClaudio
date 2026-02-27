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

    private var resetsAt: Date? {
        range == .sevenDay ? weeklyResetsAt : fiveHourResetsAt
    }

    private var barColor: Color {
        if currentUtilization >= 80 { return .red }
        if currentUtilization >= 60 { return .yellow }
        return .white
    }

    private var resetText: String {
        guard let resetsAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Resets \(formatter.localizedString(for: resetsAt, relativeTo: .now))"
    }

    private var domainStart: Date {
        Date().addingTimeInterval(-range.duration)
    }

    private var filteredReadings: [UsageReading] {
        let start = domainStart
        return readings.filter { $0.timestamp >= start }
    }

    var body: some View {
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

            if filteredReadings.count >= 2 {
                chart
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
    }

    private var chart: some View {
        Chart {
            ForEach(Array(filteredReadings.enumerated()), id: \.offset) { _, reading in
                let value = range == .sevenDay ? reading.weekly : reading.fiveHour

                AreaMark(
                    x: .value("Time", reading.timestamp),
                    y: .value("Usage", value)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [barColor.opacity(0.3), barColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Time", reading.timestamp),
                    y: .value("Usage", value)
                )
                .foregroundStyle(barColor.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartXScale(domain: domainStart...Date())
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: range == .sevenDay ? 7 : 5)) { value in
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
