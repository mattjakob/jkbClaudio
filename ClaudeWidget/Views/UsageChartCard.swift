import Charts
import SwiftUI

struct UsageChartCard: View {
    let readings: [UsageReading]
    let currentUtilization: Double
    let resetsAt: Date?
    let isLoading: Bool

    private var chartColor: Color {
        if currentUtilization >= 80 { return .red }
        if currentUtilization >= 60 { return .yellow }
        return .white
    }

    private var resetText: String {
        guard let resetsAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "resets \(formatter.localizedString(for: resetsAt, relativeTo: .now))"
    }

    private var dayLabels: [Date] {
        let calendar = Calendar.current
        let now = Date()
        return (0..<7).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: now)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(currentUtilization))%")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(chartColor)

                Text("weekly")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                }

                if !resetText.isEmpty {
                    Text(resetText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if readings.count >= 2 {
                Chart {
                    ForEach(Array(readings.enumerated()), id: \.offset) { _, reading in
                        AreaMark(
                            x: .value("Time", reading.timestamp),
                            y: .value("Usage", reading.weekly)
                        )
                        .foregroundStyle(
                            .linearGradient(
                                colors: [chartColor.opacity(0.3), chartColor.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Time", reading.timestamp),
                            y: .value("Usage", reading.weekly)
                        )
                        .foregroundStyle(chartColor.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: dayLabels) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: .dateTime.weekday(.abbreviated))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
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
            } else {
                Text("Collecting usage data...")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 80)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
