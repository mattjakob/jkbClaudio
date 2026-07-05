import Foundation

struct ProcessInfo: Sendable {
    let pid: String
    let path: String
    let elapsedSeconds: Int
    let memoryMB: Double
    let cpuPercent: Double
    /// Running claude processes descended from this one (Task subagents,
    /// auto security reviewers, SDK children).
    let childAgents: Int
}

actor SessionService {
    private let claudeDir: String
    private let projectsDir: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.claudeDir = "\(home)/.claude"
        self.projectsDir = "\(home)/.claude/projects"
    }

    func getActiveSessions() -> [SessionEntry] {
        let processInfos = getClaudeProcessInfos()
        var results: [SessionEntry] = []
        var usedSessionPaths: Set<String> = []

        for info in processInfos {
            let processStart = Date().addingTimeInterval(-Double(info.elapsedSeconds))
            if var session = findSessionForPath(info.path, excluding: usedSessionPaths,
                                                processStart: processStart) {
                if !session.fullPath.isEmpty { usedSessionPaths.insert(session.fullPath) }
                enrichSession(&session)
                session.pid = Int(info.pid) ?? 0
                session.elapsedSeconds = info.elapsedSeconds
                session.memoryMB = info.memoryMB
                session.cpuPercent = info.cpuPercent
                // Add live child agent processes on top of the transcript's
                // pending Task subagents.
                session.subagentCount += info.childAgents
                results.append(session)
            }
        }

        // Also include very recently ended sessions (5 min grace period for final stats)
        let coveredPaths = Set(results.map(\.projectPath))
        let allIndexed = loadAllSessions()
        let cutoff = Date().addingTimeInterval(-300)
        for var session in allIndexed {
            if !coveredPaths.contains(session.projectPath),
               let modified = session.modifiedDate, modified > cutoff {
                enrichSession(&session)
                results.append(session)
            }
        }

        pruneEnrichCaches()
        return results.sorted { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
    }

    /// Resolves the most recently active session JSONL for a process cwd.
    ///
    /// Selection is by real filesystem mtime, NOT by the `modified` field in
    /// `sessions-index.json` — that field is not reliably updated by Claude
    /// Code (observed entries from 60+ days ago in indexes whose project
    /// jsonl was modified minutes ago). The index is still queried for
    /// metadata enrichment (firstPrompt, summary, gitBranch) when an entry
    /// matching the chosen file exists.
    private func findSessionForPath(_ projectPath: String, excluding usedPaths: Set<String> = [],
                                    processStart: Date? = nil) -> SessionEntry? {
        let fm = FileManager.default
        let dirName = projectPath.replacingOccurrences(of: "/", with: "-")
        let candidates = [dirName] + parentDirNames(dirName)

        for candidate in candidates {
            let dirPath = "\(projectsDir)/\(candidate)"
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }

            var stats: [(file: String, mtime: Date, birth: Date)] = []
            for file in files where file.hasSuffix(".jsonl") {
                let filePath = "\(dirPath)/\(file)"
                if usedPaths.contains(filePath) { continue }
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                let birth = (attrs[.creationDate] as? Date) ?? mtime
                stats.append((file, mtime, birth))
            }

            // The primary session's transcript is the EARLIEST-created file
            // among those written since the process started — subagent
            // transcripts (reviewers, Task agents) are created later, so
            // "newest mtime" would mis-attribute the row while agents run.
            var chosen: (file: String, mtime: Date, birth: Date)?
            if let processStart {
                let sinceStart = stats.filter { $0.mtime >= processStart.addingTimeInterval(-60) }
                chosen = sinceStart.min { $0.birth < $1.birth }
            }
            if chosen == nil {
                chosen = stats.max { $0.mtime < $1.mtime }
            }
            guard let picked = chosen else { continue }
            let file = picked.file
            let latestMtime = picked.mtime

            let fullPath = "\(dirPath)/\(file)"
            let sessionId = String(file.dropLast(6))
            let modifiedISO = ISO8601DateFormatter.standard.string(from: latestMtime)

            // Optional metadata from index.
            if let data = fm.contents(atPath: "\(dirPath)/sessions-index.json"),
               let index = try? JSONDecoder().decode(SessionsIndex.self, from: data),
               let entry = index.entries.first(where: { $0.fullPath == fullPath || $0.sessionId == sessionId }) {
                // Override the index's stale `modified` with the real one.
                return SessionEntry(
                    sessionId: entry.sessionId,
                    fullPath: fullPath,
                    fileMtime: Int64(latestMtime.timeIntervalSince1970 * 1000),
                    firstPrompt: entry.firstPrompt,
                    summary: entry.summary,
                    messageCount: entry.messageCount,
                    created: entry.created,
                    modified: modifiedISO,
                    gitBranch: entry.gitBranch,
                    projectPath: projectPath,
                    isSidechain: entry.isSidechain
                )
            }

            return SessionEntry(
                sessionId: sessionId,
                fullPath: fullPath,
                fileMtime: Int64(latestMtime.timeIntervalSince1970 * 1000),
                firstPrompt: nil, summary: nil, messageCount: 0,
                created: modifiedISO, modified: modifiedISO,
                gitBranch: nil, projectPath: projectPath, isSidechain: false
            )
        }

        // No jsonl found anywhere — return a placeholder with current time so
        // the row at least shows a valid (zero) idle duration.
        let nowISO = ISO8601DateFormatter.standard.string(from: Date())
        return SessionEntry(
            sessionId: UUID().uuidString, fullPath: "",
            fileMtime: Int64(Date().timeIntervalSince1970 * 1000),
            firstPrompt: nil, summary: nil, messageCount: 0,
            created: nowISO, modified: nowISO,
            gitBranch: nil, projectPath: projectPath, isSidechain: false
        )
    }

    /// Per-transcript running aggregates so each poll parses only bytes
    /// appended since the last one. Only metrics with actual consumers
    /// (SessionRow, Telegram /status) are computed.
    private struct EnrichCache {
        var parsedBytes = 0
        var assistantTurns = 0
        var totalDurationMs: Int64 = 0
        var pendingTaskIds: Set<String> = []
        var completedTaskIds: Set<String> = []
        var model: String?
        var gitBranch: String?
        var firstPrompt: String?
        var permissionMode: String?
        var lastAccess = Date()
    }

    private var enrichCaches: [String: EnrichCache] = [:]

    private func enrichSession(_ session: inout SessionEntry) {
        let fm = FileManager.default
        guard !session.fullPath.isEmpty,
              let attrs = try? fm.attributesOfItem(atPath: session.fullPath),
              let size = (attrs[.size] as? NSNumber)?.intValue else { return }

        // Actual filesystem mtime (ground truth for last activity).
        if let mtime = attrs[.modificationDate] as? Date {
            session.actualFileMtime = Int64(mtime.timeIntervalSince1970 * 1000)
        }

        var cache = enrichCaches[session.fullPath] ?? EnrichCache()
        if size < cache.parsedBytes { cache = EnrichCache() }  // rewritten/truncated

        if size > cache.parsedBytes,
           let handle = FileHandle(forReadingAtPath: session.fullPath) {
            defer { try? handle.close() }
            if (try? handle.seek(toOffset: UInt64(cache.parsedBytes))) != nil,
               let data = try? handle.readToEnd(), !data.isEmpty,
               let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                let complete = data[data.startIndex...lastNewline]
                for line in complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                    parseTranscriptLine(Data(line), into: &cache)
                }
                cache.parsedBytes += complete.count
            }
        }

        cache.lastAccess = Date()
        enrichCaches[session.fullPath] = cache

        session.assistantTurns = cache.assistantTurns
        session.subagentCount = max(0, cache.pendingTaskIds.count - cache.completedTaskIds.count)
        session.totalDurationMs = cache.totalDurationMs
        if let permissionMode = cache.permissionMode { session.permissionMode = permissionMode }
        if let branch = cache.gitBranch { session.gitBranch = branch }
        if let model = cache.model { session.model = model }
        if session.firstPrompt == nil, let firstPrompt = cache.firstPrompt {
            session.firstPrompt = firstPrompt
        }
    }

    private func parseTranscriptLine(_ line: Data, into cache: inout EnrichCache) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let type = obj["type"] as? String ?? ""

        if cache.gitBranch == nil, let b = obj["gitBranch"] as? String {
            cache.gitBranch = b
        }

        switch type {
        case "user":
            if cache.permissionMode == nil, let pm = obj["permissionMode"] as? String {
                cache.permissionMode = pm
            }
            if let result = obj["toolUseResult"] as? [String: Any],
               let dur = (result["durationMs"] as? Int64) ?? (result["durationMs"] as? Int).map(Int64.init) {
                cache.totalDurationMs += dur
            }
            if let msg = obj["message"] as? [String: Any] {
                if cache.firstPrompt == nil, let content = msg["content"] as? String {
                    cache.firstPrompt = String(content.prefix(80))
                }
                if let content = msg["content"] as? [[String: Any]] {
                    for block in content
                    where block["type"] as? String == "tool_result" {
                        if let toolUseId = block["tool_use_id"] as? String,
                           cache.pendingTaskIds.contains(toolUseId) {
                            cache.completedTaskIds.insert(toolUseId)
                        }
                    }
                }
            }

        case "assistant":
            cache.assistantTurns += 1
            if let msg = obj["message"] as? [String: Any] {
                if cache.model == nil, let m = msg["model"] as? String, m != "<synthetic>" {
                    cache.model = m
                }
                if let content = msg["content"] as? [[String: Any]] {
                    for block in content where block["type"] as? String == "tool_use" {
                        if block["name"] as? String == "Task", let id = block["id"] as? String {
                            cache.pendingTaskIds.insert(id)
                        }
                    }
                }
            }

        case "system":
            if let dur = (obj["durationMs"] as? Int64) ?? (obj["durationMs"] as? Int).map(Int64.init) {
                cache.totalDurationMs += dur
            }

        default:
            break
        }
    }

    /// Drop caches for transcripts not touched in a while (ended sessions).
    private func pruneEnrichCaches() {
        let cutoff = Date().addingTimeInterval(-1800)
        enrichCaches = enrichCaches.filter { $0.value.lastAccess > cutoff }
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

    /// Returns sessions whose .jsonl was modified within the last 5 minutes —
    /// used to keep recently-ended sessions visible briefly. Real fs mtime
    /// only; the sessions-index.json's `modified` field is unreliable.
    private func loadAllSessions() -> [SessionEntry] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }
        let cutoff = Date().addingTimeInterval(-300)

        var sessions: [SessionEntry] = []
        for dir in projectDirs {
            let dirPath = "\(projectsDir)/\(dir)"
            // Skip whole project dir if it hasn't been touched recently. This
            // avoids walking jsonls in dormant projects (potentially 100+).
            guard let dirMtime = (try? fm.attributesOfItem(atPath: dirPath))?[.modificationDate] as? Date,
                  dirMtime > cutoff else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = "\(dirPath)/\(file)"
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let mtime = attrs[.modificationDate] as? Date,
                      mtime > cutoff else { continue }

                let projectPath = "/" + dir.dropFirst().replacingOccurrences(of: "-", with: "/")
                let modifiedISO = ISO8601DateFormatter.standard.string(from: mtime)
                sessions.append(SessionEntry(
                    sessionId: String(file.dropLast(6)),
                    fullPath: filePath,
                    fileMtime: Int64(mtime.timeIntervalSince1970 * 1000),
                    firstPrompt: nil, summary: nil, messageCount: 0,
                    created: modifiedISO, modified: modifiedISO,
                    gitBranch: nil, projectPath: projectPath, isSidechain: false
                ))
            }
        }
        return sessions
    }

    // MARK: - Process detection

    /// Splits claude PIDs into primary sessions and subagents. A process
    /// descended from another claude process (through any number of
    /// intermediate shells) is a subagent, attributed to its TOPMOST claude
    /// ancestor so nested agents roll up to the interactive session.
    static func classifyAgents(pids: Set<Int>, parentMap: [Int: Int])
        -> (primaries: Set<Int>, owners: [Int: Int]) {
        var primaries: Set<Int> = []
        var owners: [Int: Int] = [:]

        for pid in pids {
            var ancestor = parentMap[pid]
            var owner: Int?
            var hops = 0
            while let current = ancestor, current > 1, hops < 64 {
                if pids.contains(current), current != pid { owner = current }
                ancestor = parentMap[current]
                hops += 1
            }
            if let owner {
                owners[pid] = owner
            } else {
                primaries.insert(pid)
            }
        }
        return (primaries, owners)
    }

    /// Snapshot of pid -> ppid for all processes.
    private nonisolated func processParentMap() -> [Int: Int] {
        let pipe = Pipe()
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-ax", "-o", "pid=,ppid="]
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run(); ps.waitUntilExit() } catch { return [:] }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        var map: [Int: Int] = [:]
        for line in output.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard parts.count >= 2, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { continue }
            map[pid] = ppid
        }
        return map
    }

    private nonisolated func getClaudeProcessInfos() -> [ProcessInfo] {
        let pgrepPipe = Pipe()
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "claude"]
        pgrep.standardOutput = pgrepPipe
        pgrep.standardError = FileHandle.nullDevice

        do { try pgrep.run(); pgrep.waitUntilExit() } catch { return [] }

        let pgrepData = pgrepPipe.fileHandleForReading.readDataToEndOfFile()
        let allPids = String(data: pgrepData, encoding: .utf8)?
            .components(separatedBy: "\n")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? []

        guard !allPids.isEmpty else { return [] }

        // Subagent processes (Task agents, auto reviewers) don't get their
        // own session row — they count toward their root session's agents.
        let (primaries, owners) = Self.classifyAgents(
            pids: Set(allPids), parentMap: processParentMap()
        )
        let pids = allPids.filter { primaries.contains($0) }.map(String.init)
        guard !pids.isEmpty else { return [] }

        // Stats for ALL agent processes: children's memory/CPU roll up into
        // their owning session so the row reflects the whole agent tree.
        let psPipe = Pipe()
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", allPids.map(String.init).joined(separator: ","),
                        "-o", "pid=,etime=,rss=,%cpu="]
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

        // Fold each child's memory/CPU into its owning primary.
        var childCounts: [Int: Int] = [:]
        var childMem: [Int: Double] = [:]
        var childCpu: [Int: Double] = [:]
        for (child, owner) in owners {
            childCounts[owner, default: 0] += 1
            let stats = pidStats[String(child)] ?? (0, 0, 0)
            childMem[owner, default: 0] += stats.memMB
            childCpu[owner, default: 0] += stats.cpu
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
                let pidInt = Int(pid) ?? 0
                results.append(ProcessInfo(
                    pid: pid,
                    path: path,
                    elapsedSeconds: stats.elapsed,
                    memoryMB: stats.memMB + (childMem[pidInt] ?? 0),
                    cpuPercent: stats.cpu + (childCpu[pidInt] ?? 0),
                    childAgents: childCounts[pidInt] ?? 0
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
