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

struct DailyModelTokens: Codable, Sendable {
    let date: String
    let tokensByModel: [String: Int64]
}

struct StatsCache: Codable, Sendable {
    let version: Int
    let lastComputedDate: String
    let dailyActivity: [DailyActivity]
    let dailyModelTokens: [DailyModelTokens]?
    let modelUsage: [String: ModelTokens]
    let totalSessions: Int
    let totalMessages: Int
    let firstSessionDate: String?
    let hourCounts: [String: Int]?
}

struct WeeklyStats: Sendable {
    var sessions: Int = 0
    var messages: Int = 0
    var totalTokens: Int64 = 0
    var dailyActivity: [DailyActivity] = []
}
