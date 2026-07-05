import Foundation

/// Incrementally aggregates token usage from Claude Code transcript JSONL
/// files. Each snapshot() call rescans only files whose size/mtime changed,
/// parsing just the appended tail. Dedup state and file offsets persist to
/// a cache file so relaunches don't reparse gigabytes.
actor TokenScanner {
    private struct FileState: Codable {
        var mtime: TimeInterval
        var size: Int
        var parsedBytes: Int
    }

    private struct Cache: Codable {
        var files: [String: FileState] = [:]
        var entries: [String: ParsedTokenUsage] = [:]
    }

    /// Files whose mtime is older than this can't contribute to today.
    private static let staleFileAge: TimeInterval = 2 * 86_400

    private let roots: [String]
    private let cachePath: String
    private var cache: Cache?

    init(roots: [String]? = nil, cachePath: String? = nil) {
        if let roots {
            self.roots = roots
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var resolved: [String] = []
            if let env = Foundation.ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
                resolved = env.split(separator: ",").map { "\($0)/projects" }
            }
            if resolved.isEmpty {
                resolved = ["\(home)/.claude/projects", "\(home)/.config/claude/projects"]
            }
            self.roots = resolved
        }
        self.cachePath = cachePath
            ?? NSHomeDirectory() + "/Library/Caches/Claudio/token-scan-v1.json"
    }

    func snapshot() -> TokenUsageSnapshot {
        var cache = loadCache()
        let fm = FileManager.default
        let now = Date()

        for root in roots {
            guard let enumerator = fm.enumerator(atPath: root) else { continue }
            for case let relative as String in enumerator where relative.hasSuffix(".jsonl") {
                let path = "\(root)/\(relative)"
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                      let size = (attrs[.size] as? NSNumber)?.intValue else { continue }

                if now.timeIntervalSince1970 - mtime > Self.staleFileAge { continue }

                let prior = cache.files[path]
                if let prior, prior.mtime == mtime, prior.size == size { continue }

                // Rewritten/truncated files reparse from zero.
                let offset = (prior != nil && size >= prior!.parsedBytes) ? prior!.parsedBytes : 0
                let parsedUpTo = parseTail(path: path, from: offset, into: &cache.entries)
                cache.files[path] = FileState(mtime: mtime, size: size, parsedBytes: parsedUpTo)
            }
        }

        pruneOldEntries(&cache, now: now)
        self.cache = cache
        saveCache(cache)
        return aggregate(cache, now: now)
    }

    // MARK: - Parsing

    /// Parses complete lines in [from, EOF); returns the byte offset just
    /// past the last newline so a partial trailing line is re-read next pass.
    private func parseTail(path: String, from offset: Int,
                           into entries: inout [String: ParsedTokenUsage]) -> Int {
        guard let handle = FileHandle(forReadingAtPath: path) else { return offset }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return offset }

        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return offset }
        let complete = data[data.startIndex...lastNewline]

        for line in complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            if let parsed = TokenLineParser.parse(Data(line), calendar: .current) {
                entries[parsed.dedupKey] = parsed
            }
        }
        return offset + complete.count
    }

    // MARK: - Aggregation

    private func aggregate(_ cache: Cache, now: Date) -> TokenUsageSnapshot {
        let today = TokenLineParser.day(from: now, calendar: .current)
        var perModel: [String: TokenCounts] = [:]
        var total = TokenCounts()
        for entry in cache.entries.values where entry.day == today {
            perModel[entry.model, default: TokenCounts()].add(entry.counts)
            total.add(entry.counts)
        }
        return TokenUsageSnapshot(today: perModel, todayTotal: total)
    }

    private func pruneOldEntries(_ cache: inout Cache, now: Date) {
        let today = TokenLineParser.day(from: now, calendar: .current)
        let yesterday = TokenLineParser.day(from: now.addingTimeInterval(-86_400), calendar: .current)
        cache.entries = cache.entries.filter { $0.value.day == today || $0.value.day == yesterday }
    }

    // MARK: - Cache persistence

    private func loadCache() -> Cache {
        if let cache { return cache }
        guard let data = FileManager.default.contents(atPath: cachePath),
              let decoded = try? JSONDecoder().decode(Cache.self, from: data) else {
            return Cache()
        }
        return decoded
    }

    private func saveCache(_ cache: Cache) {
        let url = URL(fileURLWithPath: cachePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
