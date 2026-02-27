import Foundation

struct SessionEntry: Codable, Identifiable, Sendable {
    let sessionId: String
    let fullPath: String
    let fileMtime: Int64
    var firstPrompt: String?
    let summary: String?
    let messageCount: Int
    let created: String
    let modified: String
    var gitBranch: String?
    let projectPath: String
    let isSidechain: Bool

    // Rich stats (parsed from .jsonl when available)
    var userMessages: Int = 0
    var assistantTurns: Int = 0
    var toolCalls: Int = 0
    var subagentCount: Int = 0
    var tokensIn: Int64 = 0
    var tokensOut: Int64 = 0
    var model: String?
    var topTools: [String: Int] = [:]
    var permissionMode: String?
    var totalDurationMs: Int64 = 0

    // Process-level stats (from ps)
    var elapsedSeconds: Int = 0
    var memoryMB: Double = 0
    var cpuPercent: Double = 0

    var id: String { sessionId }

    var createdDate: Date? {
        ISO8601DateFormatter.withFractionalSeconds.date(from: created)
            ?? ISO8601DateFormatter.standard.date(from: created)
    }

    var modifiedDate: Date? {
        ISO8601DateFormatter.withFractionalSeconds.date(from: modified)
            ?? ISO8601DateFormatter.standard.date(from: modified)
    }

    var projectName: String {
        projectPath.components(separatedBy: "/").last ?? projectPath
    }

    enum CodingKeys: String, CodingKey {
        case sessionId, fullPath, fileMtime, firstPrompt, summary, messageCount
        case created, modified, gitBranch, projectPath, isSidechain
    }
}

struct SessionsIndex: Codable, Sendable {
    let version: Int
    let entries: [SessionEntry]
}
