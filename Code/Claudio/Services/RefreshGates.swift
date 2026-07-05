import Foundation

/// Persisted gates preventing retry storms against the usage endpoint and
/// the OAuth refresh endpoint. State lives in UserDefaults so backoff
/// survives relaunch. Pure value type; injectable clock for tests.
struct RefreshGates: Sendable {
    /// UserDefaults is documented thread-safe; it just lacks a Sendable
    /// annotation in the SDK.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let now: @Sendable () -> Date

    private static let rateLimitKey = "gates.rateLimitedUntil"
    private static let authFingerprintKey = "gates.authBlockedFingerprint"
    private static let transientUntilKey = "gates.transientBlockedUntil"
    private static let transientCountKey = "gates.transientFailureCount"

    private static let defaultRateLimitCooldown: TimeInterval = 300
    private static let transientBase: TimeInterval = 300
    private static let transientCap: TimeInterval = 21_600

    init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    // MARK: - 429 gate

    func recordRateLimit(retryAfterHeader: String?) {
        let interval = Self.parseRetryAfter(retryAfterHeader, now: now())
        defaults.set(now().addingTimeInterval(interval).timeIntervalSince1970,
                     forKey: Self.rateLimitKey)
    }

    /// Non-nil while the 429 cooldown is in the future.
    func rateLimitedUntil() -> Date? {
        let ts = defaults.double(forKey: Self.rateLimitKey)
        guard ts > 0 else { return nil }
        let until = Date(timeIntervalSince1970: ts)
        return until > now() ? until : nil
    }

    func clearRateLimit() {
        defaults.removeObject(forKey: Self.rateLimitKey)
    }

    /// Retry-After per RFC 9110: delta-seconds or HTTP-date. Defaults to
    /// 300 s when absent or unparseable.
    static func parseRetryAfter(_ value: String?, now: Date) -> TimeInterval {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return defaultRateLimitCooldown
        }
        if let seconds = TimeInterval(value), seconds > 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value), date > now {
            return date.timeIntervalSince(now)
        }
        return defaultRateLimitCooldown
    }

    // MARK: - OAuth refresh failure gates

    /// Terminal failure (invalid_grant): blocked until credentials change.
    func recordAuthFailure(fingerprint: String) {
        defaults.set(fingerprint, forKey: Self.authFingerprintKey)
    }

    /// Blocked only while the stored fingerprint still matches — a changed
    /// fingerprint means the user re-authenticated, so retry is allowed.
    func isAuthBlocked(currentFingerprint: String) -> Bool {
        guard let blocked = defaults.string(forKey: Self.authFingerprintKey) else { return false }
        if blocked == currentFingerprint { return true }
        defaults.removeObject(forKey: Self.authFingerprintKey)
        return false
    }

    /// Transient failure: exponential backoff 5 min doubling to 6 h cap.
    @discardableResult
    func recordTransientFailure() -> Date {
        let count = defaults.integer(forKey: Self.transientCountKey) + 1
        defaults.set(count, forKey: Self.transientCountKey)
        let interval = min(Self.transientBase * pow(2, Double(count - 1)), Self.transientCap)
        let until = now().addingTimeInterval(interval)
        defaults.set(until.timeIntervalSince1970, forKey: Self.transientUntilKey)
        return until
    }

    func transientBlockedUntil() -> Date? {
        let ts = defaults.double(forKey: Self.transientUntilKey)
        guard ts > 0 else { return nil }
        let until = Date(timeIntervalSince1970: ts)
        return until > now() ? until : nil
    }

    /// Cleared on any successful refresh or credential change.
    func clearFailures() {
        defaults.removeObject(forKey: Self.authFingerprintKey)
        defaults.removeObject(forKey: Self.transientUntilKey)
        defaults.removeObject(forKey: Self.transientCountKey)
    }
}
