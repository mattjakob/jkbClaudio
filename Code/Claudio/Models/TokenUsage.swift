import Foundation

struct TokenCounts: Equatable, Codable, Sendable {
    var input = 0
    var output = 0
    var cacheCreate = 0
    var cacheRead = 0

    var total: Int { input + output + cacheCreate + cacheRead }

    mutating func add(_ other: TokenCounts) {
        input += other.input
        output += other.output
        cacheCreate += other.cacheCreate
        cacheRead += other.cacheRead
    }
}

struct TokenUsageSnapshot: Equatable, Sendable {
    let today: [String: TokenCounts]
    let todayTotal: TokenCounts

    static let empty = TokenUsageSnapshot(today: [:], todayTotal: TokenCounts())
}

struct ParsedTokenUsage: Equatable, Codable, Sendable {
    let dedupKey: String
    let model: String
    let day: String
    let counts: TokenCounts
}

/// Parses one transcript JSONL line. Lines are only JSON-decoded after the
/// byte-level `quickFilter` matches, keeping full-directory scans cheap.
enum TokenLineParser {
    private static let typeMarker = Data(#""type":"assistant""#.utf8)
    private static let usageMarker = Data(#""usage""#.utf8)
    static let maxLineBytes = 512 * 1024

    static func quickFilter(_ line: Data) -> Bool {
        line.count <= maxLineBytes
            && line.range(of: typeMarker) != nil
            && line.range(of: usageMarker) != nil
    }

    private struct Line: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }
        }
    }

    static func parse(_ line: Data, calendar: Calendar) -> ParsedTokenUsage? {
        guard quickFilter(line),
              let decoded = try? JSONDecoder().decode(Line.self, from: line),
              decoded.type == "assistant",
              let message = decoded.message,
              let model = message.model,
              let usage = message.usage,
              let timestamp = decoded.timestamp else { return nil }

        let date = ISO8601DateFormatter.withFractionalSeconds.date(from: timestamp)
            ?? ISO8601DateFormatter.standard.date(from: timestamp)
        guard let date else { return nil }

        // Streaming chunks of one API call share message.id + requestId;
        // the caller overwrites by key so the final cumulative chunk wins.
        let dedupKey: String
        if message.id != nil || decoded.requestId != nil {
            dedupKey = "\(message.id ?? "-")|\(decoded.requestId ?? "-")"
        } else {
            dedupKey = "line|\(UUID().uuidString)"
        }

        return ParsedTokenUsage(
            dedupKey: dedupKey,
            model: model,
            day: day(from: date, calendar: calendar),
            counts: TokenCounts(
                input: usage.inputTokens ?? 0,
                output: usage.outputTokens ?? 0,
                cacheCreate: usage.cacheCreationInputTokens ?? 0,
                cacheRead: usage.cacheReadInputTokens ?? 0
            )
        )
    }

    static func day(from date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

func compactTokens(_ n: Int) -> String {
    switch n {
    case ..<1000: return "\(n)"
    case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1000)
    default: return String(format: "%.1fM", Double(n) / 1_000_000)
    }
}
