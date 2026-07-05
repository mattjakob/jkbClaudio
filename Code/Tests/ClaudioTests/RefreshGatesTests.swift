import Testing
import Foundation
@testable import Claudio

@Suite struct RefreshGatesTests {
    private func makeGates(now: Date = Date(timeIntervalSince1970: 1_000_000)) -> (RefreshGates, UserDefaults) {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (RefreshGates(defaults: defaults, now: { now }), defaults)
    }

    @Test func parseRetryAfterSeconds() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(RefreshGates.parseRetryAfter("120", now: now) == 120)
    }

    @Test func parseRetryAfterHTTPDate() {
        let now = ISO8601DateFormatter().date(from: "2026-07-05T12:00:00Z")!
        let interval = RefreshGates.parseRetryAfter("Sun, 05 Jul 2026 12:03:00 GMT", now: now)
        #expect(abs(interval - 180) < 1)
    }

    @Test func parseRetryAfterAbsentDefaultsTo300() {
        #expect(RefreshGates.parseRetryAfter(nil, now: Date()) == 300)
        #expect(RefreshGates.parseRetryAfter("garbage", now: Date()) == 300)
    }

    @Test func rateLimitGateBlocksAndClears() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (gates, _) = makeGates(now: now)
        #expect(gates.rateLimitedUntil() == nil)
        gates.recordRateLimit(retryAfterHeader: "60")
        #expect(gates.rateLimitedUntil() == now.addingTimeInterval(60))
        gates.clearRateLimit()
        #expect(gates.rateLimitedUntil() == nil)
    }

    @Test func expiredRateLimitIsNil() {
        final class DateBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _date: Date
            init(_ date: Date) { _date = date }
            var date: Date {
                get { lock.lock(); defer { lock.unlock() }; return _date }
                set { lock.lock(); defer { lock.unlock() }; _date = newValue }
            }
        }
        let box = DateBox(Date(timeIntervalSince1970: 1_000_000))
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let gates = RefreshGates(defaults: defaults, now: { box.date })
        gates.recordRateLimit(retryAfterHeader: "60")
        box.date = box.date.addingTimeInterval(61)
        #expect(gates.rateLimitedUntil() == nil)
    }

    @Test func authGateKeyedToFingerprint() {
        let (gates, _) = makeGates()
        gates.recordAuthFailure(fingerprint: "abc")
        #expect(gates.isAuthBlocked(currentFingerprint: "abc"))
        #expect(!gates.isAuthBlocked(currentFingerprint: "def"))
    }

    @Test func transientBackoffDoublesAndCaps() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (gates, _) = makeGates(now: now)
        #expect(gates.recordTransientFailure() == now.addingTimeInterval(300))
        #expect(gates.recordTransientFailure() == now.addingTimeInterval(600))
        #expect(gates.recordTransientFailure() == now.addingTimeInterval(1200))
        for _ in 0..<10 { _ = gates.recordTransientFailure() }
        #expect(gates.recordTransientFailure() == now.addingTimeInterval(21_600))
        gates.clearFailures()
        #expect(gates.transientBlockedUntil() == nil)
        #expect(gates.recordTransientFailure() == now.addingTimeInterval(300))
    }
}
