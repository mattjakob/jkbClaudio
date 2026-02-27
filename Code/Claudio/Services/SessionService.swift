import Foundation

struct ProcessInfo: Sendable {
    let path: String
    let elapsedSeconds: Int
    let memoryMB: Double
    let cpuPercent: Double
}

actor SessionService {
    private let claudeDir: String
    private let projectsDir: String

    // Cache for indexed sessions — invalidated when directory mtime changes
    private var indexCache: [String: (mtime: Date, entries: [SessionEntry])] = [:]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.claudeDir = "\(home)/.claude"
        self.projectsDir = "\(home)/.claude/projects"
    }

    func getActiveSessions() -> [SessionEntry] {
        let processInfos = getClaudeProcessInfos()
        var results: [SessionEntry] = []

        for info in processInfos {
            if var session = findSessionForPath(info.path) {
                enrichSession(&session)
                session.elapsedSeconds = info.elapsedSeconds
                session.memoryMB = info.memoryMB
                session.cpuPercent = info.cpuPercent
                results.append(session)
            }
        }

        // Also include recent indexed sessions not already covered
        let coveredPaths = Set(results.map(\.projectPath))
        let allIndexed = loadAllSessions()
        let cutoff = Date().addingTimeInterval(-86400)
        for var session in allIndexed {
            if !coveredPaths.contains(session.projectPath),
               let modified = session.modifiedDate, modified > cutoff {
                enrichSession(&session)
                results.append(session)
            }
        }

        return results.sorted { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
    }

    private func findSessionForPath(_ projectPath: String) -> SessionEntry? {
        let fm = FileManager.default
        let dirName = projectPath.replacingOccurrences(of: "/", with: "-")
        let candidates = [dirName] + parentDirNames(dirName)

        for candidate in candidates {
            let dirPath = "\(projectsDir)/\(candidate)"

            let indexPath = "\(dirPath)/sessions-index.json"
            if let data = fm.contents(atPath: indexPath),
               let index = try? JSONDecoder().decode(SessionsIndex.self, from: data),
               let latest = index.entries.sorted(by: { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }).first {
                return latest
            }

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
                let sessionId = String(file.dropLast(6))
                return SessionEntry(
                    sessionId: sessionId,
                    fullPath: "\(dirPath)/\(file)",
                    fileMtime: Int64(latestMtime.timeIntervalSince1970 * 1000),
                    firstPrompt: nil, summary: nil, messageCount: 0,
                    created: ISO8601DateFormatter.standard.string(from: latestMtime),
                    modified: ISO8601DateFormatter.standard.string(from: latestMtime),
                    gitBranch: nil, projectPath: projectPath, isSidechain: false
                )
            }
        }

        return SessionEntry(
            sessionId: UUID().uuidString, fullPath: "",
            fileMtime: Int64(Date().timeIntervalSince1970 * 1000),
            firstPrompt: nil, summary: nil, messageCount: 0,
            created: ISO8601DateFormatter.standard.string(from: Date()),
            modified: ISO8601DateFormatter.standard.string(from: Date()),
            gitBranch: nil, projectPath: projectPath, isSidechain: false
        )
    }

    private func enrichSession(_ session: inout SessionEntry) {
        guard !session.fullPath.isEmpty,
              let data = FileManager.default.contents(atPath: session.fullPath) else { return }

        let lines = data.split(separator: UInt8(ascii: "\n"))
        var userMsgs = 0
        var assistantTurns = 0
        var toolCalls = 0
        var subagents = 0
        var tokensIn: Int64 = 0
        var tokensOut: Int64 = 0
        var totalDurationMs: Int64 = 0
        var tools: [String: Int] = [:]
        var branch: String?
        var model: String?
        var firstPrompt: String?
        var permissionMode: String?

        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }

            let type = obj["type"] as? String ?? ""

            if branch == nil, let b = obj["gitBranch"] as? String {
                branch = b
            }

            if type == "user" {
                userMsgs += 1
                if permissionMode == nil, let pm = obj["permissionMode"] as? String {
                    permissionMode = pm
                }
                if firstPrompt == nil,
                   let msg = obj["message"] as? [String: Any],
                   let content = msg["content"] as? String {
                    firstPrompt = String(content.prefix(80))
                }
            }

            if type == "assistant" {
                assistantTurns += 1
                if let msg = obj["message"] as? [String: Any] {
                    if model == nil, let m = msg["model"] as? String {
                        model = m
                    }
                    if let usage = msg["usage"] as? [String: Any] {
                        tokensIn += (usage["input_tokens"] as? Int64) ?? Int64(usage["input_tokens"] as? Int ?? 0)
                        tokensIn += (usage["cache_read_input_tokens"] as? Int64) ?? Int64(usage["cache_read_input_tokens"] as? Int ?? 0)
                        tokensOut += (usage["output_tokens"] as? Int64) ?? Int64(usage["output_tokens"] as? Int ?? 0)
                    }
                    if let content = msg["content"] as? [[String: Any]] {
                        for block in content {
                            if block["type"] as? String == "tool_use" {
                                toolCalls += 1
                                let name = block["name"] as? String ?? "unknown"
                                tools[name, default: 0] += 1
                                if name == "Task" { subagents += 1 }
                            }
                        }
                    }
                }
            }

            if type == "system" {
                if let dur = obj["durationMs"] as? Int64 {
                    totalDurationMs += dur
                } else if let dur = obj["durationMs"] as? Int {
                    totalDurationMs += Int64(dur)
                }
            }
        }

        session.userMessages = userMsgs
        session.assistantTurns = assistantTurns
        session.toolCalls = toolCalls
        session.subagentCount = subagents
        session.tokensIn = tokensIn
        session.tokensOut = tokensOut
        session.topTools = tools
        session.totalDurationMs = totalDurationMs
        if let permissionMode { session.permissionMode = permissionMode }
        if let branch { session.gitBranch = branch }
        if let model { session.model = model }
        if session.firstPrompt == nil, let firstPrompt { session.firstPrompt = firstPrompt }
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

    private func loadAllSessions() -> [SessionEntry] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }

        var sessions: [SessionEntry] = []
        for dir in projectDirs {
            let dirPath = "\(projectsDir)/\(dir)"
            let indexPath = "\(dirPath)/sessions-index.json"

            // Check directory mtime for cache invalidation
            let dirMtime = (try? fm.attributesOfItem(atPath: dirPath))?[.modificationDate] as? Date

            if let dirMtime, let cached = indexCache[dir], cached.mtime == dirMtime {
                sessions.append(contentsOf: cached.entries)
                continue
            }

            guard let data = fm.contents(atPath: indexPath) else { continue }
            guard let index = try? JSONDecoder().decode(SessionsIndex.self, from: data) else { continue }
            indexCache[dir] = (mtime: dirMtime ?? .distantPast, entries: index.entries)
            sessions.append(contentsOf: index.entries)
        }
        return sessions
    }

    // MARK: - Process detection

    private nonisolated func getClaudeProcessInfos() -> [ProcessInfo] {
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

        // Get process stats via ps
        let psPipe = Pipe()
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", pids.joined(separator: ","), "-o", "pid=,etime=,rss=,%cpu="]
        ps.standardOutput = psPipe
        ps.standardError = FileHandle.nullDevice

        do { try ps.run(); ps.waitUntilExit() } catch { return [] }

        let psData = psPipe.fileHandleForReading.readDataToEndOfFile()
        let psOutput = String(data: psData, encoding: .utf8) ?? ""

        var pidStats: [String: (elapsed: Int, memMB: Double, cpu: Double)] = [:]
        for line in psOutput.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard parts.count >= 4 else { continue }
            let pid = parts[0]
            let elapsed = parseElapsed(parts[1])
            let rssKB = Double(parts[2]) ?? 0
            let cpu = Double(parts[3]) ?? 0
            pidStats[pid] = (elapsed, rssKB / 1024.0, cpu)
        }

        // Get CWDs via lsof
        let lsofPipe = Pipe()
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-a", "-d", "cwd", "-p", pids.joined(separator: ","), "-Fpn"]
        lsof.standardOutput = lsofPipe
        lsof.standardError = FileHandle.nullDevice

        do { try lsof.run(); lsof.waitUntilExit() } catch { return [] }

        let lsofData = lsofPipe.fileHandleForReading.readDataToEndOfFile()
        let lsofOutput = String(data: lsofData, encoding: .utf8) ?? ""

        var results: [ProcessInfo] = []
        var currentPid: String?
        for line in lsofOutput.components(separatedBy: "\n") {
            if line.hasPrefix("p") {
                currentPid = String(line.dropFirst(1))
            } else if line.hasPrefix("n/"), let pid = currentPid {
                let path = String(line.dropFirst(1))
                let stats = pidStats[pid] ?? (0, 0, 0)
                results.append(ProcessInfo(
                    path: path,
                    elapsedSeconds: stats.elapsed,
                    memoryMB: stats.memMB,
                    cpuPercent: stats.cpu
                ))
            }
        }
        return results
    }

    /// Parse ps etime format: [[dd-]hh:]mm:ss
    private nonisolated func parseElapsed(_ etime: String) -> Int {
        var total = 0
        var str = etime

        if let dashIdx = str.firstIndex(of: "-") {
            let days = Int(str[str.startIndex..<dashIdx]) ?? 0
            total += days * 86400
            str = String(str[str.index(after: dashIdx)...])
        }

        let parts = str.components(separatedBy: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: total += parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: total += parts[0] * 60 + parts[1]
        case 1: total += parts[0]
        default: break
        }
        return total
    }
}
