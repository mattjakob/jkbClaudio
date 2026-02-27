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
        var results: [SessionEntry] = []

        // For each running claude process, find or create a session entry
        for projectPath in activeProjectPaths {
            if let session = findSessionForPath(projectPath) {
                results.append(session)
            }
        }

        // Also include recent indexed sessions not already covered
        let coveredPaths = Set(results.map(\.projectPath))
        let allIndexed = loadAllSessions()
        let cutoff = Date().addingTimeInterval(-86400)
        for session in allIndexed {
            if !coveredPaths.contains(session.projectPath),
               let modified = session.modifiedDate, modified > cutoff {
                results.append(session)
            }
        }

        return results.sorted { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
    }

    private func findSessionForPath(_ projectPath: String) -> SessionEntry? {
        let fm = FileManager.default

        // Convert project path to claude's directory naming convention
        // /Users/mattjakob/Documents/Code/Python/jkbTrader -> -Users-mattjakob-Documents-Code-Python-jkbTrader
        let dirName = projectPath.replacingOccurrences(of: "/", with: "-")

        // Try exact match first, then parent directories
        let candidates = [dirName] + parentDirNames(dirName)

        for candidate in candidates {
            let dirPath = "\(projectsDir)/\(candidate)"

            // Try sessions-index.json first
            let indexPath = "\(dirPath)/sessions-index.json"
            if let data = fm.contents(atPath: indexPath),
               let index = try? JSONDecoder().decode(SessionsIndex.self, from: data),
               let latest = index.entries.sorted(by: { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }).first {
                return latest
            }

            // Fall back to most recently modified .jsonl file
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }

            var latestFile: String?
            var latestMtime: Date = .distantPast

            for file in jsonlFiles {
                let filePath = "\(dirPath)/\(file)"
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                if mtime > latestMtime {
                    latestMtime = mtime
                    latestFile = file
                }
            }

            if let file = latestFile {
                let sessionId = String(file.dropLast(6)) // remove .jsonl
                return SessionEntry(
                    sessionId: sessionId,
                    fullPath: "\(dirPath)/\(file)",
                    fileMtime: Int64(latestMtime.timeIntervalSince1970 * 1000),
                    firstPrompt: nil,
                    summary: nil,
                    messageCount: 0,
                    created: ISO8601DateFormatter().string(from: latestMtime),
                    modified: ISO8601DateFormatter().string(from: latestMtime),
                    gitBranch: nil,
                    projectPath: projectPath,
                    isSidechain: false
                )
            }
        }

        // No session files found — create a minimal entry from the process info
        let projectName = projectPath.components(separatedBy: "/").last ?? projectPath
        return SessionEntry(
            sessionId: UUID().uuidString,
            fullPath: "",
            fileMtime: Int64(Date().timeIntervalSince1970 * 1000),
            firstPrompt: nil,
            summary: nil,
            messageCount: 0,
            created: ISO8601DateFormatter().string(from: Date()),
            modified: ISO8601DateFormatter().string(from: Date()),
            gitBranch: nil,
            projectPath: projectPath,
            isSidechain: false
        )
    }

    private func parentDirNames(_ dirName: String) -> [String] {
        var parts = dirName.components(separatedBy: "-").filter { !$0.isEmpty }
        var results: [String] = []
        while parts.count > 1 {
            parts.removeLast()
            results.append("-" + parts.joined(separator: "-"))
        }
        return results
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
