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
                }

                HStack(spacing: 8) {
                    if let branch = session.gitBranch {
                        Text(branch)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(session.messageCount) msgs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(timeAgo)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
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
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
