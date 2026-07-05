import Foundation

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let standard = ISO8601DateFormatter()
}

struct UsageWindow: Codable, Sendable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        return ISO8601DateFormatter.withFractionalSeconds.date(from: resetsAt)
    }
}

struct ExtraUsage: Codable, Sendable {
    let isEnabled: Bool
    let monthlyLimit: Int?
    let usedCredits: Int?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

struct LimitScopeModel: Codable, Sendable {
    let id: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

struct LimitScope: Codable, Sendable {
    let model: LimitScopeModel?
}

/// Entry in the newer `limits[]` response shape (superseding flat
/// `seven_day_*` keys). `is_active` is deliberately ignored — the API
/// reports false for enforceable scoped limits.
struct UsageLimit: Codable, Sendable {
    let kind: String?
    let group: String?
    let percent: Double?
    let resetsAt: String?
    let scope: LimitScope?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, scope
        case resetsAt = "resets_at"
    }
}

struct NamedUsageWindow: Sendable, Equatable {
    let name: String
    let utilization: Double
    let resetsAt: Date?
}

struct UsageResponse: Codable, Sendable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOauthApps: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let extraUsage: ExtraUsage?
    let limits: [UsageLimit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
        case limits
    }

    /// Model-scoped windows from `limits[]` that carry displayable data —
    /// e.g. promo windows for a specific model family.
    func scopedWindows() -> [NamedUsageWindow] {
        (limits ?? []).compactMap { limit in
            guard let percent = limit.percent,
                  let name = limit.scope?.model?.displayName ?? limit.scope?.model?.id else {
                return nil
            }
            let resets = limit.resetsAt.flatMap {
                ISO8601DateFormatter.withFractionalSeconds.date(from: $0)
                    ?? ISO8601DateFormatter.standard.date(from: $0)
            }
            return NamedUsageWindow(name: name, utilization: percent, resetsAt: resets)
        }
    }
}

struct OAuthCredentials: Codable, Sendable {
    struct ClaudeAiOauth: Codable, Sendable {
        let accessToken: String
        let refreshToken: String
        /// Token expiration in milliseconds since Unix epoch. Optional because
        /// older `.credentials.json` versions and some keychain rewrites may
        /// omit it.
        let expiresAt: Double?
        let subscriptionType: String?
        let scopes: [String]?
    }
    let claudeAiOauth: ClaudeAiOauth

    /// True if the access token is expired or within `buffer` of expiry.
    /// Returns true when no expiry is recorded (fail safe → refresh).
    func needsRefresh(buffer: TimeInterval = 5 * 60) -> Bool {
        guard let expiresAt = claudeAiOauth.expiresAt else { return true }
        let nowMs = Date().timeIntervalSince1970 * 1000
        return nowMs + buffer * 1000 >= expiresAt
    }
}
