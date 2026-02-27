import SwiftUI

struct SessionRow: View {
    let session: SessionEntry
    let isActive: Bool

    private var timeAgo: String {
        guard let modified = session.modifiedDate else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: modified, relativeTo: .now)
    }

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
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isActive ? .green : .gray.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.projectName)
                        .font(.callout)
                        .fontWeight(.medium)
                    if !isActive {
                        Text("idle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(timeAgo)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    if let branch = session.gitBranch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if session.userMessages > 0 {
                        Label("\(session.userMessages)", systemImage: "text.bubble")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if session.messageCount > 0 {
                        Label("\(session.messageCount)", systemImage: "text.bubble")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if session.toolCalls > 0 {
                        Label("\(session.toolCalls)", systemImage: "wrench")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if session.subagentCount > 0 {
                        Label("\(session.subagentCount)", systemImage: "person.2")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if session.tokensIn > 0 || session.tokensOut > 0 {
                    HStack(spacing: 8) {
                        Label("\(formatTokens(session.tokensIn)) in", systemImage: "arrow.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Label("\(formatTokens(session.tokensOut)) out", systemImage: "arrow.up")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

struct SessionCard: View {
    let sessions: [SessionEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active Sessions")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            if sessions.isEmpty {
                Text("No recent sessions")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(sessions.prefix(5))) { session in
                    SessionRow(
                        session: session,
                        isActive: session.modifiedDate.map { $0.timeIntervalSinceNow > -300 } ?? false
                    )
                    if session.id != sessions.prefix(5).last?.id {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
