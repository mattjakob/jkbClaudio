import Foundation

actor SessionService {
    private let claudeDir: String
    private let projectsDir: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.claudeDir = "\(home)/.claude"
        self.projectsDir = "\(home)/.claude/projects"
    }

    func getActiveSessions() -> [SessionEntry] {
        let activePIDs = getClaudeProcessSessionIds()
        let allSessions = loadAllSessions()

        let cutoff = Date().addingTimeInterval(-3600)
        return allSessions.filter { session in
            let isRunning = activePIDs.contains(session.sessionId)
            let isRecent = session.modifiedDate.map { $0 > cutoff } ?? false
            return isRunning || isRecent
        }
        .sorted { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
    }

    func getWeeklyStats() -> WeeklyStats {
        guard let cache = loadStatsCache() else { return WeeklyStats() }

        let calendar = Calendar.current
        let now = Date()
        guard let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) else {
            return WeeklyStats()
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let weekStartStr = dateFormatter.string(from: weekStart)

        let weeklyActivity = cache.dailyActivity.filter { $0.date >= weekStartStr }
        let sessions = weeklyActivity.reduce(0) { $0 + $1.sessionCount }
        let messages = weeklyActivity.reduce(0) { $0 + $1.messageCount }

        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        for (_, usage) in cache.modelUsage {
            inputTokens += usage.inputTokens
            outputTokens += usage.outputTokens
        }

        return WeeklyStats(
            sessions: sessions,
            messages: messages,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            dailyActivity: weeklyActivity
        )
    }

    private func loadAllSessions() -> [SessionEntry] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }

        var sessions: [SessionEntry] = []
        for dir in projectDirs {
            let indexPath = "\(projectsDir)/\(dir)/sessions-index.json"
            guard let data = fm.contents(atPath: indexPath) else { continue }
            guard let index = try? JSONDecoder().decode(SessionsIndex.self, from: data) else { continue }
            sessions.append(contentsOf: index.entries)
        }
        return sessions
    }

    private func loadStatsCache() -> StatsCache? {
        let path = "\(claudeDir)/stats-cache.json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(StatsCache.self, from: data)
    }

    private nonisolated func getClaudeProcessSessionIds() -> Set<String> {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fl", "claude"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        var sessionIds = Set<String>()
        for line in output.components(separatedBy: "\n") {
            if let range = line.range(of: "--session-id\\s+([a-f0-9-]+)", options: .regularExpression) {
                let match = line[range]
                if let idRange = match.range(of: "[a-f0-9-]{36}", options: .regularExpression) {
                    sessionIds.insert(String(match[idRange]))
                }
            }
        }
        return sessionIds
    }
}
