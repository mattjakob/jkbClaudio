import SwiftUI

struct TokenStatsCard: View {
    let usage: TokenUsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tokens Today")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                stat("In", usage.todayTotal.input)
                stat("Out", usage.todayTotal.output)
                stat("Cache W", usage.todayTotal.cacheCreate)
                stat("Cache R", usage.todayTotal.cacheRead)
            }

            if !usage.today.isEmpty {
                Divider()
                ForEach(sortedModels, id: \.0) { model, counts in
                    HStack {
                        Text(shortModelName(model))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(compactTokens(counts.total))
                            .font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private var sortedModels: [(String, TokenCounts)] {
        usage.today.sorted { $0.value.total > $1.value.total }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text(compactTokens(value))
                .font(.callout.monospacedDigit())
                .fontWeight(.medium)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func shortModelName(_ model: String) -> String {
        model
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }
}
