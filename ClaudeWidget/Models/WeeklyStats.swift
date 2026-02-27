import Foundation

struct DailyActivity: Codable, Sendable {
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
}

struct ModelTokens: Codable, Sendable {
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadInputTokens: Int64
    let cacheCreationInputTokens: Int64
}

struct StatsCache: Codable, Sendable {
    let version: Int
    let lastComputedDate: String
    let dailyActivity: [DailyActivity]
    let modelUsage: [String: ModelTokens]
    let totalSessions: Int
    let totalMessages: Int
    let firstSessionDate: String?
    let hourCounts: [String: Int]?
}

struct WeeklyStats: Sendable {
    var sessions: Int = 0
    var messages: Int = 0
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var dailyActivity: [DailyActivity] = []
}
