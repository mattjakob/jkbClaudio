import SwiftUI

struct SessionRow: View {
    let session: SessionEntry
    let isActive: Bool

    private var isWorking: Bool {
        guard isActive, let lastActivity = session.lastActivityDate else { return false }
        return Date().timeIntervalSince(lastActivity) < 120
    }

    private var statusText: String {
        let lastActivity = session.lastActivityDate

        if isActive {
            // Check if session file was written to recently (actively working)
            if let lastActivity {
                let sinceLastWrite = Date().timeIntervalSince(lastActivity)
                if sinceLastWrite < 120 {
                    if session.totalDurationMs > 0 {
                        return "\(formatDurationMs(session.totalDurationMs)) thinking"
                    }
                    return "active"
                }
                // Process running but file hasn't been written to → waiting for input
                return "\(formatDuration(max(Int(sinceLastWrite), 60))) idle"
            }
            return "\(formatDuration(session.elapsedSeconds)) active"
        }

        // No running process
        guard let lastActivity else { return "" }
        let idle = Int(Date().timeIntervalSince(lastActivity))
        return "\(formatDuration(max(idle, 60))) idle"
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
            HStack {
                Text(session.projectName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(isWorking ? Color.widgetActive : .secondary)
                Spacer()
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                if let model = modelShort {
                    Label(model, systemImage: "apple.terminal")
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

            HStack(spacing: 8) {
                if session.subagentCount > 0 {
                    Label("\(session.subagentCount) subagent\(session.subagentCount == 1 ? "" : "s")", systemImage: "sparkles.square.filled.on.square")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Label("single agent", systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

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
        let displayed = Array(sessions.prefix(5))
        VStack(alignment: .leading, spacing: 10) {
            Text("Sessions")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            if displayed.isEmpty {
                Text("No recent sessions")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ForEach(displayed.indices, id: \.self) { i in
                    SessionRow(
                        session: displayed[i],
                        isActive: displayed[i].elapsedSeconds > 0
                    )
                    if i < displayed.count - 1 {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
