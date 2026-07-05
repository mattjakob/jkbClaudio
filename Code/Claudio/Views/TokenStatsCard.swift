import SwiftUI

struct TokenStatsCard: View {
    let usage: TokenUsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tokens Today")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(modelShares, id: \.0) { model, percent in
                HStack {
                    Text(shortModelName(model))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(percent)%")
                        .font(.caption2.monospacedDigit())
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Models sorted by usage, each with its share of today's total tokens.
    /// Shares always sum to 100.
    private var modelShares: [(String, Int)] {
        let sorted = usage.today.sorted { $0.value.total > $1.value.total }
        let shares = percentageShares(sorted.map(\.value.total))
        return zip(sorted.map(\.key), shares).map { ($0, $1) }
    }

    private func shortModelName(_ model: String) -> String {
        model
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }
}
