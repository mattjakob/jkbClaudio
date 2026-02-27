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

    private var modelShort: String? {
        guard let model = session.model else { return nil }
        let parts = model.replacingOccurrences(of: "claude-", with: "")
            .components(separatedBy: "-")
        guard parts.count >= 2 else { return model }
        let name = parts[0].prefix(1).uppercased() + parts[0].dropFirst()
        let version = parts[1...].joined(separator: ".")
        return "\(name) \(version)"
    }

    private var permissionLabel: String? {
        guard let pm = session.permissionMode else { return nil }
        switch pm {
        case "bypassPermissions": return "Bypass"
        case "default": return "Default"
        case "plan": return "Plan"
        default: return pm.prefix(1).uppercased() + pm.dropFirst()
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds >= 86400 {
            let d = seconds / 86400
            let h = (seconds % 86400) / 3600
            return "\(d)d \(h)h"
        }
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return "\(h)h \(m)m"
        }
        let m = seconds / 60
        return "\(m)m"
    }

    private func formatDurationMs(_ ms: Int64) -> String {
        let seconds = Int(ms / 1000)
        if seconds >= 3600 {
            return String(format: "%.1fh", Double(ms) / 3_600_000)
        }
        if seconds >= 60 {
            return String(format: "%.0fm", Double(ms) / 60_000)
        }
        return "\(seconds)s"
    }

    private func formatMemory(_ mb: Double) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Row 1: project name + time ago
            HStack {
                Text(session.projectName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(isActive ? .green : .secondary)
                Spacer()
                Text(timeAgo)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Row 2: model + permission + branch
            HStack(spacing: 8) {
                if let model = modelShort {
                    Label(model, systemImage: "terminal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let perm = permissionLabel {
                    Label(perm, systemImage: "shield.lefthalf.filled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let branch = session.gitBranch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Row 3: subagents/terminal + turn time
            HStack(spacing: 8) {
                if session.subagentCount > 0 {
                    Label("\(session.subagentCount)", systemImage: "sparkles.square.filled.on.square")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Label("1", systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if session.totalDurationMs > 0 {
                    Label(formatDurationMs(session.totalDurationMs), systemImage: "hourglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Row 4: process stats (only for active processes)
            if isActive && session.elapsedSeconds > 0 {
                HStack(spacing: 8) {
                    Label(formatDuration(session.elapsedSeconds), systemImage: "timer")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Label(formatMemory(session.memoryMB), systemImage: "memorychip")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Label(String(format: "%.0f%%", session.cpuPercent), systemImage: "gauge.low")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct SessionCard: View {
    let sessions: [SessionEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sessions")
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
                        isActive: session.elapsedSeconds > 0
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
