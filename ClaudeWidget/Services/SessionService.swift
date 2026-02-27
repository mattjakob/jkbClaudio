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
        let activeProjectPaths = getClaudeProcessPaths()
        let allSessions = loadAllSessions()
            .sorted { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }

        // For each active claude process CWD, find the most recent session whose projectPath matches
        var activeSessions: [SessionEntry] = []
        var seenProjects = Set<String>()

        for session in allSessions {
            let isRunning = activeProjectPaths.contains { session.projectPath.hasPrefix($0) || $0.hasPrefix(session.projectPath) }
            if isRunning && !seenProjects.contains(session.projectPath) {
                seenProjects.insert(session.projectPath)
                activeSessions.append(session)
            }
        }

        // Also include recent non-running sessions (last 24h)
        let cutoff = Date().addingTimeInterval(-86400)
        for session in allSessions {
            if !seenProjects.contains(session.projectPath),
               let modified = session.modifiedDate, modified > cutoff {
                seenProjects.insert(session.projectPath)
                activeSessions.append(session)
            }
        }

        return activeSessions
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

        let weeklyTokenDays = cache.dailyModelTokens?.filter { $0.date >= weekStartStr } ?? []
        var totalTokens: Int64 = 0
        for day in weeklyTokenDays {
            for (_, tokens) in day.tokensByModel {
                totalTokens += tokens
            }
        }

        return WeeklyStats(
            sessions: sessions,
            messages: messages,
            totalTokens: totalTokens,
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

    private nonisolated func getClaudeProcessPaths() -> Set<String> {
        // Get PIDs of running claude processes
        let pgrepPipe = Pipe()
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "claude"]
        pgrep.standardOutput = pgrepPipe
        pgrep.standardError = FileHandle.nullDevice

        do { try pgrep.run(); pgrep.waitUntilExit() } catch { return [] }

        let pgrepData = pgrepPipe.fileHandleForReading.readDataToEndOfFile()
        let pids = String(data: pgrepData, encoding: .utf8)?
            .components(separatedBy: "\n")
            .compactMap { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []

        guard !pids.isEmpty else { return [] }

        // Use lsof to get the CWD of each claude process
        let lsofPipe = Pipe()
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-a", "-d", "cwd", "-p", pids.joined(separator: ",")] + ["-Fn"]
        lsof.standardOutput = lsofPipe
        lsof.standardError = FileHandle.nullDevice

        do { try lsof.run(); lsof.waitUntilExit() } catch { return [] }

        let lsofData = lsofPipe.fileHandleForReading.readDataToEndOfFile()
        let lsofOutput = String(data: lsofData, encoding: .utf8) ?? ""

        var paths = Set<String>()
        for line in lsofOutput.components(separatedBy: "\n") {
            if line.hasPrefix("n/") {
                paths.insert(String(line.dropFirst(1)))
            }
        }
        return paths
    }
}
