# Token Tracking v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden Claudio's usage-API polling (safe auth, gates, adaptive cadence) and add realtime local token counts from Claude Code JSONL transcripts.

**Architecture:** `UsageService` stops rotating Claude Code's refresh token — it piggybacks on externally refreshed credentials (fingerprint detection), delegates refresh to the `claude` CLI via PTY, and only direct-refreshes as a last resort, all behind persisted failure/429 gates. A new `TokenScanner` actor incrementally parses `~/.claude/projects/**/*.jsonl` for per-model token counts, triggered by hook events and poll ticks. `AppViewModel` replaces the fixed 120 s timer with an adaptive self-rescheduling one plus reset-boundary one-shots.

**Tech Stack:** Swift 6.2, SwiftUI, actors, CryptoKit, Swift Testing (`swift-testing` via SPM test target), no external dependencies.

## Global Constraints

- macOS 26+, Swift 6.2, SPM (`Code/Package.swift`)
- Files under 600 lines; one responsibility per file
- No emojis in code; no unrequested features
- Commit format `<tag>: summary` (<=72 chars)
- Existing behavior preserved: UI never blanks on transient failure; keychain never prompted on background paths
- Run `swift build` and `swift test` (from `Code/`) after every task

---

### Task 1: Test target + RefreshGates

**Files:**
- Modify: `Code/Package.swift`
- Create: `Code/Claudio/Services/RefreshGates.swift`
- Test: `Code/Tests/ClaudioTests/RefreshGatesTests.swift`

**Interfaces:**
- Produces: `struct RefreshGates` with `init(defaults:now:)`, `recordRateLimit(retryAfterHeader:)`, `rateLimitedUntil() -> Date?`, `clearRateLimit()`, `recordAuthFailure(fingerprint:)`, `isAuthBlocked(currentFingerprint:) -> Bool`, `recordTransientFailure() -> Date`, `transientBlockedUntil() -> Date?`, `clearFailures()`, `static parseRetryAfter(_:now:) -> TimeInterval`

- [ ] **Step 1: Add test target to Package.swift**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Claudio",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Claudio",
            path: "Claudio",
            exclude: ["Info.plist", "Claudio.entitlements"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ClaudioTests",
            dependencies: ["Claudio"],
            path: "Tests/ClaudioTests"
        )
    ]
)
```

- [ ] **Step 2: Write failing tests**

`Code/Tests/ClaudioTests/RefreshGatesTests.swift`:

```swift
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
```

- [ ] **Step 3: Run tests, verify FAIL** — `cd Code && swift test 2>&1 | tail -5` → compile error: `RefreshGates` not found.

- [ ] **Step 4: Implement `Code/Claudio/Services/RefreshGates.swift`**

```swift
import Foundation

/// Persisted gates preventing retry storms against the usage endpoint and
/// the OAuth refresh endpoint. State lives in UserDefaults so backoff
/// survives relaunch. Pure value type; injectable clock for tests.
struct RefreshGates: Sendable {
    private let defaults: UserDefaults
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
```

- [ ] **Step 5: Run tests, verify PASS** — `cd Code && swift test 2>&1 | tail -3`

- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: RefreshGates with persisted 429 and refresh-failure backoff"`

---

### Task 2: KeychainService fingerprints + external reload

**Files:**
- Modify: `Code/Claudio/Services/KeychainService.swift`
- Test: `Code/Tests/ClaudioTests/KeychainFingerprintTests.swift`

**Interfaces:**
- Produces: `KeychainService.externalFingerprint() -> String` (SHA-256 hex over credentials-file bytes + silent-keychain bytes; both optional, never prompts), `KeychainService.reloadFromExternalSources() -> OAuthCredentials?` (re-reads file then silent keychain, adopts newest into cache+mirror, never prompts). Internal seams for tests: `init(credentialsFileOverride:keychainReader:)` visible via `@testable`.

- [ ] **Step 1: Write failing tests**

`Code/Tests/ClaudioTests/KeychainFingerprintTests.swift`:

```swift
import Testing
import Foundation
@testable import Claudio

@Suite struct KeychainFingerprintTests {
    private func tempCredsFile(token: String) throws -> String {
        let dir = NSTemporaryDirectory() + "claudio-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/.credentials.json"
        let json = """
        {"claudeAiOauth":{"accessToken":"\(token)","refreshToken":"r1","expiresAt":9999999999999}}
        """
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func fingerprintChangesWhenFileChanges() throws {
        let path = try tempCredsFile(token: "a1")
        let svc = KeychainService(credentialsFileOverride: path, keychainReader: { nil })
        let fp1 = svc.externalFingerprint()
        try """
        {"claudeAiOauth":{"accessToken":"a2","refreshToken":"r2","expiresAt":9999999999999}}
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let fp2 = svc.externalFingerprint()
        #expect(fp1 != fp2)
        #expect(svc.externalFingerprint() == fp2)
    }

    @Test func fingerprintIncludesKeychainBytes() throws {
        let path = try tempCredsFile(token: "a1")
        let a = KeychainService(credentialsFileOverride: path, keychainReader: { nil })
        let b = KeychainService(credentialsFileOverride: path, keychainReader: { Data("kc".utf8) })
        #expect(a.externalFingerprint() != b.externalFingerprint())
    }

    @Test func reloadAdoptsChangedFile() throws {
        let path = try tempCredsFile(token: "a1")
        let svc = KeychainService(credentialsFileOverride: path, keychainReader: { nil })
        _ = try svc.getCredentials()
        try """
        {"claudeAiOauth":{"accessToken":"a2","refreshToken":"r2","expiresAt":9999999999999}}
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let reloaded = svc.reloadFromExternalSources()
        #expect(reloaded?.claudeAiOauth.accessToken == "a2")
        #expect(try svc.getCredentials().claudeAiOauth.accessToken == "a2")
    }
}
```

- [ ] **Step 2: Run tests, verify FAIL** (no such initializer / methods).

- [ ] **Step 3: Implement.** In `KeychainService.swift`:

Add `import CryptoKit` at top. Replace the `static let mirrorPath` / `credentialsFilePath` singleton-only design with injectable seams — change the class header and add stored properties (keep `static let shared = KeychainService()`):

```swift
final class KeychainService: Sendable {
    static let shared = KeychainService()

    private static let sourceService = "Claude Code-credentials"

    private let mirrorPath: String
    private let credentialsFilePath: String
    /// Prompt-free keychain byte reader. Injectable for tests; the default
    /// performs a silent (no-UI) SecItemCopyMatching.
    private let keychainReader: @Sendable () -> Data?

    init(credentialsFileOverride: String? = nil,
         keychainReader: (@Sendable () -> Data?)? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.credentialsFilePath = credentialsFileOverride ?? "\(home)/.claude/.credentials.json"
        self.mirrorPath = (credentialsFileOverride.map { $0 + ".mirror" })
            ?? "\(home)/.claude/widget-credentials.json"
        self.keychainReader = keychainReader ?? Self.silentKeychainBytes
    }
```

Update every `Self.mirrorPath` / `Self.credentialsFilePath` reference to the instance properties. Extract the silent keychain read into a reusable static:

```swift
    /// Prompt-free raw read of Claude Code's keychain item. Returns nil on
    /// any failure (including ACL-denied) without ever showing UI.
    private static func silentKeychainBytes() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sourceService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
```

Rewrite `readKeychainSilent()` to use it (`guard let data = Self.silentKeychainBytes() else { throw KeychainError.itemNotFound }; return try decodeAndCache(data)`).

Add the two new public methods:

```swift
    // MARK: - External change detection

    /// SHA-256 over the raw bytes of Claude Code's credentials file and its
    /// keychain item (silent read only — never prompts). Changes whenever
    /// Claude Code refreshes or the user re-authenticates.
    func externalFingerprint() -> String {
        var hasher = SHA256()
        hasher.update(data: FileManager.default.contents(atPath: credentialsFilePath) ?? Data())
        hasher.update(data: Data([0]))
        hasher.update(data: keychainReader() ?? Data())
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Re-reads Claude Code's own sources (credentials file, then silent
    /// keychain) and adopts the result into cache + mirror. Never prompts.
    /// Returns nil when neither source is readable.
    @discardableResult
    func reloadFromExternalSources() -> OAuthCredentials? {
        if let creds = readJSONFile(at: credentialsFilePath) {
            if let data = try? JSONEncoder().encode(creds) { saveMirror(data) }
            cache.set(creds)
            return creds
        }
        if let data = keychainReader(),
           let creds = try? JSONDecoder().decode(OAuthCredentials.self, from: data) {
            saveMirror(data)
            cache.set(creds)
            return creds
        }
        return nil
    }
```

(`saveMirror` switches from `Self.mirrorPath` to `mirrorPath`; `readJSONFile` unchanged.)

Note: Claude Code's keychain JSON may contain extra top-level keys (`mcpOAuth`); `OAuthCredentials` decoding already tolerates unknown keys. If `claudeAiOauth` is absent, decode fails and we correctly return nil.

- [ ] **Step 4: Run tests, verify PASS** — `cd Code && swift test 2>&1 | tail -3`
- [ ] **Step 5: Commit** — `git commit -am "feat: credential fingerprints and prompt-free external reload"`

---

### Task 3: TokenUsage model + JSONL line parser

**Files:**
- Create: `Code/Claudio/Models/TokenUsage.swift`
- Test: `Code/Tests/ClaudioTests/TokenLineParserTests.swift`

**Interfaces:**
- Produces: `struct TokenCounts { var input, output, cacheCreate, cacheRead: Int; var total: Int; mutating func add(_:) }`, `struct TokenUsageSnapshot { let today: [String: TokenCounts]; let todayTotal: TokenCounts }`, `struct ParsedTokenUsage { let dedupKey: String; let model: String; let day: String; let counts: TokenCounts }`, `enum TokenLineParser { static func parse(_ line: Data, calendar: Calendar) -> ParsedTokenUsage?; static func quickFilter(_ line: Data) -> Bool; static func day(from date: Date, calendar: Calendar) -> String }`, `func compactTokens(_ n: Int) -> String`

- [ ] **Step 1: Write failing tests**

`Code/Tests/ClaudioTests/TokenLineParserTests.swift`:

```swift
import Testing
import Foundation
@testable import Claudio

@Suite struct TokenLineParserTests {
    private let assistantLine = """
    {"type":"assistant","timestamp":"2026-07-05T10:00:00.000Z","requestId":"req_1",\
    "message":{"id":"msg_1","model":"claude-sonnet-5","usage":{"input_tokens":10,\
    "output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}}}
    """

    @Test func quickFilterMatchesOnlyAssistantUsageLines() {
        #expect(TokenLineParser.quickFilter(Data(assistantLine.utf8)))
        #expect(!TokenLineParser.quickFilter(Data(#"{"type":"user","message":{}}"#.utf8)))
        #expect(!TokenLineParser.quickFilter(Data(#"{"type":"assistant","message":{"id":"m"}}"#.utf8)))
    }

    @Test func parsesUsageFields() {
        let parsed = TokenLineParser.parse(Data(assistantLine.utf8), calendar: .current)
        #expect(parsed != nil)
        #expect(parsed?.model == "claude-sonnet-5")
        #expect(parsed?.dedupKey == "msg_1|req_1")
        #expect(parsed?.counts == TokenCounts(input: 10, output: 20, cacheCreate: 30, cacheRead: 40))
    }

    @Test func missingUsageOrModelReturnsNil() {
        let noUsage = #"{"type":"assistant","timestamp":"2026-07-05T10:00:00Z","message":{"id":"m","model":"x"}}"#
        #expect(TokenLineParser.parse(Data(noUsage.utf8), calendar: .current) == nil)
    }

    @Test func dedupKeyFallsBackWhenIdsMissing() {
        let line = """
        {"type":"assistant","timestamp":"2026-07-05T10:00:00Z",\
        "message":{"model":"m1","usage":{"input_tokens":1,"output_tokens":2}}}
        """
        let parsed = TokenLineParser.parse(Data(line.utf8), calendar: .current)
        #expect(parsed != nil)
        #expect(parsed!.dedupKey.hasPrefix("line|"))
    }

    @Test func countsAddAndTotal() {
        var a = TokenCounts(input: 1, output: 2, cacheCreate: 3, cacheRead: 4)
        a.add(TokenCounts(input: 10, output: 20, cacheCreate: 30, cacheRead: 40))
        #expect(a.total == 110)
    }

    @Test func compactFormatting() {
        #expect(compactTokens(950) == "950")
        #expect(compactTokens(12_400) == "12.4K")
        #expect(compactTokens(1_200_000) == "1.2M")
    }
}
```

- [ ] **Step 2: Run, verify FAIL.**

- [ ] **Step 3: Implement `Code/Claudio/Models/TokenUsage.swift`**

```swift
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
```

- [ ] **Step 4: Run tests, verify PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat: token usage model and transcript line parser"`

---

### Task 4: TokenScanner incremental JSONL scanner

**Files:**
- Create: `Code/Claudio/Services/TokenScanner.swift`
- Test: `Code/Tests/ClaudioTests/TokenScannerTests.swift`

**Interfaces:**
- Consumes: `TokenLineParser`, `ParsedTokenUsage`, `TokenCounts`, `TokenUsageSnapshot` (Task 3)
- Produces: `actor TokenScanner { init(roots: [String]? = nil, cachePath: String? = nil); func snapshot() async -> TokenUsageSnapshot }`

- [ ] **Step 1: Write failing tests**

`Code/Tests/ClaudioTests/TokenScannerTests.swift`:

```swift
import Testing
import Foundation
@testable import Claudio

@Suite struct TokenScannerTests {
    private func makeRoot() throws -> String {
        let dir = NSTemporaryDirectory() + "claudio-scan-\(UUID().uuidString)/projects/proj-a"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func line(id: String, req: String, model: String = "claude-sonnet-5",
                      input: Int, output: Int, timestamp: String? = nil) -> String {
        let ts = timestamp ?? ISO8601DateFormatter.standard.string(from: Date())
        return """
        {"type":"assistant","timestamp":"\(ts)","requestId":"\(req)","message":\
        {"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output)}}}
        """
    }

    @Test func aggregatesTodayByModel() async throws {
        let root = try makeRoot()
        let content = [
            line(id: "m1", req: "r1", input: 10, output: 5),
            #"{"type":"user","message":{"content":"hi"}}"#,
            line(id: "m2", req: "r2", model: "claude-opus-4-8", input: 100, output: 50)
        ].joined(separator: "\n") + "\n"
        try content.write(toFile: root + "/s1.jsonl", atomically: true, encoding: .utf8)

        let scanner = TokenScanner(roots: [String(root.dropLast("/proj-a".count))],
                                   cachePath: root + "/cache.json")
        let snap = await scanner.snapshot()
        #expect(snap.today["claude-sonnet-5"] == TokenCounts(input: 10, output: 5))
        #expect(snap.today["claude-opus-4-8"] == TokenCounts(input: 100, output: 50))
        #expect(snap.todayTotal.total == 165)
    }

    @Test func streamingChunksDedupLastWins() async throws {
        let root = try makeRoot()
        let content = [
            line(id: "m1", req: "r1", input: 10, output: 1),
            line(id: "m1", req: "r1", input: 10, output: 25)
        ].joined(separator: "\n") + "\n"
        try content.write(toFile: root + "/s1.jsonl", atomically: true, encoding: .utf8)

        let scanner = TokenScanner(roots: [String(root.dropLast("/proj-a".count))],
                                   cachePath: root + "/cache.json")
        let snap = await scanner.snapshot()
        #expect(snap.todayTotal == TokenCounts(input: 10, output: 25))
    }

    @Test func incrementalTailParseOnly() async throws {
        let root = try makeRoot()
        let path = root + "/s1.jsonl"
        try (line(id: "m1", req: "r1", input: 10, output: 5) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        let scanner = TokenScanner(roots: [String(root.dropLast("/proj-a".count))],
                                   cachePath: root + "/cache.json")
        _ = await scanner.snapshot()

        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        handle.write(Data((line(id: "m2", req: "r2", input: 7, output: 3) + "\n").utf8))
        try handle.close()

        let snap = await scanner.snapshot()
        #expect(snap.todayTotal == TokenCounts(input: 17, output: 8))
    }

    @Test func partialTrailingLineIsNotConsumed() async throws {
        let root = try makeRoot()
        let path = root + "/s1.jsonl"
        let full = line(id: "m1", req: "r1", input: 10, output: 5) + "\n"
        let partial = String(line(id: "m2", req: "r2", input: 99, output: 99).prefix(40))
        try (full + partial).write(toFile: path, atomically: true, encoding: .utf8)

        let scanner = TokenScanner(roots: [String(root.dropLast("/proj-a".count))],
                                   cachePath: root + "/cache.json")
        var snap = await scanner.snapshot()
        #expect(snap.todayTotal == TokenCounts(input: 10, output: 5))

        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        let rest = String(line(id: "m2", req: "r2", input: 99, output: 99).dropFirst(40)) + "\n"
        handle.write(Data(rest.utf8))
        try handle.close()

        snap = await scanner.snapshot()
        #expect(snap.todayTotal == TokenCounts(input: 109, output: 104))
    }

    @Test func oldDaysExcludedFromToday() async throws {
        let root = try makeRoot()
        let content = line(id: "m1", req: "r1", input: 500, output: 500,
                           timestamp: "2020-01-01T00:00:00Z") + "\n"
        try content.write(toFile: root + "/old.jsonl", atomically: true, encoding: .utf8)
        let scanner = TokenScanner(roots: [String(root.dropLast("/proj-a".count))],
                                   cachePath: root + "/cache.json")
        let snap = await scanner.snapshot()
        #expect(snap.todayTotal == TokenCounts())
    }
}
```

- [ ] **Step 2: Run, verify FAIL.**

- [ ] **Step 3: Implement `Code/Claudio/Services/TokenScanner.swift`**

```swift
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
            if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
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
```

- [ ] **Step 4: Run tests, verify PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat: incremental JSONL token scanner with dedup and tail parsing"`

---

### Task 5: Delegated refresh via claude CLI + version detection

**Files:**
- Create: `Code/Claudio/Services/ClaudeDelegatedRefresh.swift`
- Test: `Code/Tests/ClaudioTests/ClaudeCLITests.swift`

**Interfaces:**
- Consumes: fingerprint closure (caller passes `KeychainService.externalFingerprint`)
- Produces: `enum ClaudeCLI { static func detectVersion() async -> String?; static func parseVersion(from: String) -> String? }`, `actor ClaudeDelegatedRefresh { func attempt(fingerprint: @escaping @Sendable () -> String) async -> Bool }`

- [ ] **Step 1: Write failing tests** (version parsing + poll helper only; the PTY path is exercised in end-to-end verification, not unit tests)

`Code/Tests/ClaudioTests/ClaudeCLITests.swift`:

```swift
import Testing
import Foundation
@testable import Claudio

@Suite struct ClaudeCLITests {
    @Test func parsesVersionFromCLIOutput() {
        #expect(ClaudeCLI.parseVersion(from: "2.1.34 (Claude Code)") == "2.1.34")
        #expect(ClaudeCLI.parseVersion(from: "claude 3.0.1\n") == "3.0.1")
        #expect(ClaudeCLI.parseVersion(from: "no digits here") == nil)
    }

    @Test func pollDetectsFingerprintChange() async {
        let box = FingerprintBox(values: ["a", "a", "b"])
        let changed = await ClaudeDelegatedRefresh.pollForChange(
            initial: "a", fingerprint: { box.next() },
            delays: [0.01, 0.01, 0.01])
        #expect(changed)
    }

    @Test func pollTimesOutWithoutChange() async {
        let changed = await ClaudeDelegatedRefresh.pollForChange(
            initial: "a", fingerprint: { "a" }, delays: [0.01, 0.01])
        #expect(!changed)
    }
}

final class FingerprintBox: @unchecked Sendable {
    private var values: [String]
    private let lock = NSLock()
    init(values: [String]) { self.values = values }
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        return values.count > 1 ? values.removeFirst() : values[0]
    }
}
```

- [ ] **Step 2: Run, verify FAIL.**

- [ ] **Step 3: Implement `Code/Claudio/Services/ClaudeDelegatedRefresh.swift`**

```swift
import Foundation
import Darwin

/// Helpers for the installed `claude` CLI.
enum ClaudeCLI {
    /// Runs `claude --version` (2 s timeout) and extracts "x.y.z".
    static func detectVersion() async -> String? {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["claude", "--version"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

        let deadline = Task {
            try await Task.sleep(for: .seconds(2))
            if proc.isRunning { proc.terminate() }
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                proc.waitUntilExit()
                deadline.cancel()
                guard proc.terminationStatus == 0 else {
                    continuation.resume(returning: nil); return
                }
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
                continuation.resume(returning: parseVersion(from: output))
            }
        }
    }

    static func parseVersion(from output: String) -> String? {
        guard let range = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else {
            return nil
        }
        return String(output[range])
    }
}

/// Refreshes Claude Code's OAuth token WITHOUT touching the refresh token
/// ourselves: spawns `claude` in a PTY, sends `/status` (no model call, no
/// token cost), and waits for the external credentials fingerprint to
/// change — proof the CLI refreshed and persisted new credentials.
actor ClaudeDelegatedRefresh {
    private var lastAttempt: Date?
    private static let attemptCooldown: TimeInterval = 60

    /// Returns true if the credentials fingerprint changed (CLI refreshed).
    func attempt(fingerprint: @escaping @Sendable () -> String) async -> Bool {
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.attemptCooldown {
            return false
        }
        lastAttempt = Date()

        let initial = fingerprint()
        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return false }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["claude"]
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        proc.environment = env
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        // Drain PTY output so the CLI never blocks on a full buffer.
        masterHandle.readabilityHandler = { handle in _ = handle.availableData }

        defer {
            masterHandle.readabilityHandler = nil
            if proc.isRunning { proc.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak proc] in
                if let proc, proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }

        do { try proc.run() } catch { return false }

        // Give the CLI time to boot; startup alone refreshes an expired
        // token, /status additionally touches the auth path.
        try? await Task.sleep(for: .seconds(2))
        if fingerprint() != initial { return true }
        try? masterHandle.write(contentsOf: Data("/status\r".utf8))

        return await Self.pollForChange(initial: initial, fingerprint: fingerprint,
                                        delays: [0.3, 0.5, 0.8, 1.2, 2.0])
    }

    /// Polls until fingerprint() differs from initial, sleeping through the
    /// given delays. Separated for testability.
    static func pollForChange(initial: String,
                              fingerprint: @Sendable () -> String,
                              delays: [TimeInterval]) async -> Bool {
        for delay in delays {
            try? await Task.sleep(for: .seconds(delay))
            if fingerprint() != initial { return true }
        }
        return fingerprint() != initial
    }
}
```

- [ ] **Step 4: Run tests, verify PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat: delegated OAuth refresh via claude CLI PTY probe"`

---

### Task 6: UsageData limits[] + sonnet window

**Files:**
- Modify: `Code/Claudio/Models/UsageData.swift`
- Test: `Code/Tests/ClaudioTests/UsageResponseDecodingTests.swift`

**Interfaces:**
- Produces on `UsageResponse`: `let sevenDaySonnet: UsageWindow?`, `let limits: [UsageLimit]?`, and `func scopedWindows() -> [NamedUsageWindow]`. New types: `struct UsageLimit { kind, group: String?; percent: Double?; resetsAt: String?; scope: LimitScope? }`, `struct LimitScope { model: LimitScopeModel? }`, `struct LimitScopeModel { id: String?; displayName: String? }`, `struct NamedUsageWindow { name: String; utilization: Double; resetsAt: Date? }`

- [ ] **Step 1: Write failing tests**

`Code/Tests/ClaudioTests/UsageResponseDecodingTests.swift`:

```swift
import Testing
import Foundation
@testable import Claudio

@Suite struct UsageResponseDecodingTests {
    @Test func decodesFlatWindowsAndSonnet() throws {
        let json = """
        {"five_hour":{"utilization":42.5,"resets_at":"2026-07-05T15:00:00.000Z"},
         "seven_day":{"utilization":80,"resets_at":null},
         "seven_day_sonnet":{"utilization":12,"resets_at":null},
         "unknown_future_key":{"foo":1}}
        """
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        #expect(response.fiveHour?.utilization == 42.5)
        #expect(response.sevenDaySonnet?.utilization == 12)
    }

    @Test func decodesLimitsArray() throws {
        let json = """
        {"limits":[{"kind":"weekly_scoped","percent":33.3,
          "resets_at":"2026-07-08T00:00:00Z","is_active":false,
          "scope":{"model":{"id":"claude-fable-5","display_name":"Fable"}}},
         {"kind":"mystery","percent":null}]}
        """
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        #expect(response.limits?.count == 2)
        let scoped = response.scopedWindows()
        #expect(scoped.count == 1)
        #expect(scoped[0].name == "Fable")
        #expect(scoped[0].utilization == 33.3)
        #expect(scoped[0].resetsAt != nil)
    }

    @Test func limitsAbsentIsNil() throws {
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data("{}".utf8))
        #expect(response.limits == nil)
        #expect(response.scopedWindows().isEmpty)
    }
}
```

- [ ] **Step 2: Run, verify FAIL.**

- [ ] **Step 3: Implement.** In `UsageData.swift`, add after `ExtraUsage`:

```swift
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
```

Extend `UsageResponse`:

```swift
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
```

- [ ] **Step 4: Run tests, verify PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat: decode seven_day_sonnet and limits[] scoped windows"`

---

### Task 7: RefreshPolicy (adaptive cadence)

**Files:**
- Create: `Code/Claudio/Services/RefreshPolicy.swift`
- Test: `Code/Tests/ClaudioTests/RefreshPolicyTests.swift`

**Interfaces:**
- Produces: `enum RefreshPolicy { static func interval(hasActiveSessions: Bool, lastPopoverOpen: Date?, lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState, now: Date) -> TimeInterval }`

- [ ] **Step 1: Write failing tests**

`Code/Tests/ClaudioTests/RefreshPolicyTests.swift`:

```swift
import Testing
import Foundation
@testable import Claudio

@Suite struct RefreshPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func activeSessionsPollFast() {
        #expect(RefreshPolicy.interval(hasActiveSessions: true, lastPopoverOpen: nil,
                                       lowPowerMode: false, thermalState: .nominal, now: now) == 120)
    }

    @Test func recentPopoverPollsFast() {
        let opened = now.addingTimeInterval(-200)
        #expect(RefreshPolicy.interval(hasActiveSessions: false, lastPopoverOpen: opened,
                                       lowPowerMode: false, thermalState: .nominal, now: now) == 120)
    }

    @Test func idlePollsSlow() {
        let opened = now.addingTimeInterval(-3600)
        #expect(RefreshPolicy.interval(hasActiveSessions: false, lastPopoverOpen: opened,
                                       lowPowerMode: false, thermalState: .nominal, now: now) == 900)
        #expect(RefreshPolicy.interval(hasActiveSessions: false, lastPopoverOpen: nil,
                                       lowPowerMode: false, thermalState: .nominal, now: now) == 900)
    }

    @Test func lowPowerAndThermalOverride() {
        #expect(RefreshPolicy.interval(hasActiveSessions: true, lastPopoverOpen: now,
                                       lowPowerMode: true, thermalState: .nominal, now: now) == 1800)
        #expect(RefreshPolicy.interval(hasActiveSessions: true, lastPopoverOpen: now,
                                       lowPowerMode: false, thermalState: .critical, now: now) == 1800)
        #expect(RefreshPolicy.interval(hasActiveSessions: true, lastPopoverOpen: now,
                                       lowPowerMode: false, thermalState: .serious, now: now) == 1800)
    }
}
```

- [ ] **Step 2: Run, verify FAIL.**

- [ ] **Step 3: Implement `Code/Claudio/Services/RefreshPolicy.swift`**

```swift
import Foundation

/// Pure policy for the usage poll interval. Fast while Claude Code is in
/// active use, slow when idle, slowest under power/thermal pressure.
enum RefreshPolicy {
    static let fast: TimeInterval = 120
    static let idle: TimeInterval = 900
    static let constrained: TimeInterval = 1800
    static let popoverRecency: TimeInterval = 300

    static func interval(hasActiveSessions: Bool,
                         lastPopoverOpen: Date?,
                         lowPowerMode: Bool,
                         thermalState: ProcessInfo.ThermalState,
                         now: Date = Date()) -> TimeInterval {
        if lowPowerMode || thermalState == .serious || thermalState == .critical {
            return constrained
        }
        if hasActiveSessions { return fast }
        if let lastPopoverOpen, now.timeIntervalSince(lastPopoverOpen) < popoverRecency {
            return fast
        }
        return idle
    }
}
```

- [ ] **Step 4: Run tests, verify PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat: adaptive refresh policy"`

---

### Task 8: UsageService rewire (auth order, gates, UA)

**Files:**
- Modify: `Code/Claudio/Services/UsageService.swift`

**Interfaces:**
- Consumes: `RefreshGates` (Task 1), `KeychainService.externalFingerprint/reloadFromExternalSources` (Task 2), `ClaudeDelegatedRefresh`, `ClaudeCLI.detectVersion` (Task 5)
- Produces: `UsageService.fetchUsage(userInitiated: Bool = false) async throws -> UsageResponse`; new `UsageError` cases `.backoff(until: Date?)` (silent — keep previous data) and existing cases unchanged.

No new unit tests (network actor); correctness is covered by the gate/fingerprint tests above plus Task 11's end-to-end run. Build must stay green.

- [ ] **Step 1: Extend `UsageError`**

```swift
enum UsageError: Error, LocalizedError {
    case rateLimited
    case serverError(Int)
    case authExpired
    /// Fetch skipped by a gate (backoff/rate-limit window). Not shown as an
    /// error — the UI keeps the previous snapshot.
    case backoff(until: Date?)

    var errorDescription: String? {
        switch self {
        case .rateLimited: nil
        case .serverError(let code): "Usage API returned \(code)"
        case .authExpired: "Session expired — relaunch Claude Code to re-authenticate"
        case .backoff: nil
        }
    }
}
```

- [ ] **Step 2: Rewrite `UsageService` auth flow.** Full new body of the actor (keep `apiURL`, `refreshURL`, `clientId`, `session` as-is):

```swift
actor UsageService {
    // ... apiURL / refreshURL / clientId / session unchanged ...

    private let gates = RefreshGates()
    private let delegatedRefresh = ClaudeDelegatedRefresh()
    private var userAgent: String?

    func fetchUsage(userInitiated: Bool = false) async throws -> UsageResponse {
        if !userInitiated, let until = gates.rateLimitedUntil() {
            throw UsageError.backoff(until: until)
        }
        let token = try await currentAccessToken(userInitiated: userInitiated)
        return try await request(with: token, hasRefreshed: false, userInitiated: userInitiated)
    }

    /// Returns a non-expired access token WITHOUT ever rotating Claude
    /// Code's refresh token on the normal path:
    ///   1. cached credentials still valid -> use them
    ///   2. piggyback: Claude Code refreshed externally -> adopt its token
    ///   3. delegate: `claude` CLI PTY probe refreshes for us
    ///   4. last resort: direct OAuth refresh with our mirror's token
    private func currentAccessToken(userInitiated: Bool) async throws -> String {
        let creds = try KeychainService.shared.getCredentials()
        guard creds.needsRefresh() else { return creds.claudeAiOauth.accessToken }

        // 1. Piggyback on an external refresh (common case: Claude Code
        //    is in active use and refreshes its own token).
        if let fresh = KeychainService.shared.reloadFromExternalSources(),
           !fresh.needsRefresh() {
            gates.clearFailures()
            return fresh.claudeAiOauth.accessToken
        }

        let fingerprint = KeychainService.shared.externalFingerprint()
        if gates.isAuthBlocked(currentFingerprint: fingerprint) {
            throw UsageError.authExpired
        }
        if !userInitiated, let until = gates.transientBlockedUntil() {
            throw UsageError.backoff(until: until)
        }

        // 2. Delegate the refresh to the claude CLI (keeps ownership of the
        //    refresh token with Claude Code).
        if await delegatedRefresh.attempt(fingerprint: {
            KeychainService.shared.externalFingerprint()
        }) {
            if let fresh = KeychainService.shared.reloadFromExternalSources(),
               !fresh.needsRefresh() {
                gates.clearFailures()
                return fresh.claudeAiOauth.accessToken
            }
        }

        // 3. Last resort: direct refresh against our mirror's refresh token.
        do {
            let token = try await refresh(using: creds.claudeAiOauth.refreshToken)
            gates.clearFailures()
            return token
        } catch UsageError.authExpired {
            gates.recordAuthFailure(fingerprint: fingerprint)
            throw UsageError.authExpired
        } catch {
            gates.recordTransientFailure()
            throw error
        }
    }

    private func request(with token: String, hasRefreshed: Bool,
                         userInitiated: Bool) async throws -> UsageResponse {
        var req = URLRequest(url: apiURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(await resolvedUserAgent(), forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.serverError(0)
        }

        switch http.statusCode {
        case 200:
            gates.clearRateLimit()
            return try JSONDecoder().decode(UsageResponse.self, from: data)

        case 401:
            guard !hasRefreshed else { throw UsageError.authExpired }
            let newToken = try await recoverToken(stale: token, userInitiated: userInitiated)
            return try await request(with: newToken, hasRefreshed: true,
                                     userInitiated: userInitiated)

        case 429:
            gates.recordRateLimit(retryAfterHeader:
                http.value(forHTTPHeaderField: "Retry-After"))
            throw UsageError.rateLimited

        default:
            throw UsageError.serverError(http.statusCode)
        }
    }

    /// 401 with a token we thought was valid: external sources first, then
    /// delegation, then direct refresh, then keychain recovery (may prompt,
    /// existing last-resort behavior).
    private func recoverToken(stale: String, userInitiated: Bool) async throws -> String {
        if let fresh = KeychainService.shared.reloadFromExternalSources(),
           fresh.claudeAiOauth.accessToken != stale {
            return fresh.claudeAiOauth.accessToken
        }
        if await delegatedRefresh.attempt(fingerprint: {
            KeychainService.shared.externalFingerprint()
        }), let fresh = KeychainService.shared.reloadFromExternalSources(),
           fresh.claudeAiOauth.accessToken != stale {
            return fresh.claudeAiOauth.accessToken
        }
        if let token = try? await refreshWithCachedRefreshToken() {
            gates.clearFailures()
            return token
        }
        guard let recovered = KeychainService.shared.recoverFromKeychain() else {
            throw UsageError.authExpired
        }
        let access = recovered.claudeAiOauth.accessToken
        if access != stale { return access }
        return try await refresh(using: recovered.claudeAiOauth.refreshToken)
    }

    private func resolvedUserAgent() async -> String {
        if let userAgent { return userAgent }
        let version = await ClaudeCLI.detectVersion() ?? "2.1.0"
        let ua = "claude-code/\(version)"
        userAgent = ua
        return ua
    }
```

- [ ] **Step 3: Update `refresh(using:)` to signal invalid_grant.** Replace its error handling section:

```swift
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.serverError(0)
        }
        guard http.statusCode == 200 else {
            struct OAuthErrorBody: Decodable { let error: String? }
            let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data)
            if body?.error == "invalid_grant" {
                throw UsageError.authExpired
            }
            throw UsageError.serverError(http.statusCode)
        }
```

(The rest of `refresh(using:)`, `refreshWithCachedRefreshToken`, and the mirror write stay as they are. Delete the old `acquireFreshToken`; `recoverToken` replaces it. Update the doc comment at the top of the file to describe the piggyback → delegate → direct order.)

- [ ] **Step 4: Build + full test suite** — `cd Code && swift build && swift test 2>&1 | tail -3` → green.
- [ ] **Step 5: Commit** — `git commit -am "feat: piggyback/delegated auth order with persisted gates in UsageService"`

---

### Task 9: AppViewModel wiring (adaptive timer, reset boundary, scanner)

**Files:**
- Modify: `Code/Claudio/ViewModel/AppViewModel.swift`
- Modify: `Code/Claudio/Services/HookServer.swift` (1 insertion)

**Interfaces:**
- Consumes: `RefreshPolicy` (Task 7), `TokenScanner` (Task 4), `UsageService.fetchUsage(userInitiated:)` + `UsageError.backoff` (Task 8), `UsageResponse.scopedWindows()` (Task 6)
- Produces: `AppViewModel.tokenUsage: TokenUsageSnapshot`, `AppViewModel.scopedWindows: [NamedUsageWindow]`, `AppViewModel.popoverOpened()`, `Notification.Name.claudioHookEvent`

- [ ] **Step 1: Post a notification from HookServer.** In `HookServer.processRequest`, immediately after a `HookEvent` is successfully decoded (the `parseBody` result is non-nil and about to be dispatched to `onEvent`), add:

```swift
NotificationCenter.default.post(name: .claudioHookEvent, object: nil)
```

and at file bottom:

```swift
extension Notification.Name {
    static let claudioHookEvent = Notification.Name("claudioHookEvent")
}
```

- [ ] **Step 2: Rewire AppViewModel.** Changes:

New state and services (replacing `pollTimer`):

```swift
    var tokenUsage: TokenUsageSnapshot = .empty
    var scopedWindows: [NamedUsageWindow] = []

    private let tokenScanner = TokenScanner()
    private var pollTask: Task<Void, Never>?
    private var resetBoundaryTask: Task<Void, Never>?
    private var lastScheduledBoundary: Date?
    private var lastPopoverOpen: Date?
    private var hookObserver: NSObjectProtocol?
    private var scanDebounce: Task<Void, Never>?
```

`startPolling` becomes a self-rescheduling loop plus hook observation:

```swift
    func startPolling() {
        guard pollTask == nil else { return }

        activity = Foundation.ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Background usage polling"
        )

        hookObserver = NotificationCenter.default.addObserver(
            forName: .claudioHookEvent, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleTokenScan() }
        }

        pollTask = Task { [weak self] in
            guard let self else { return }
            await historyService.load()
            usageHistory = await historyService.getReadings()
            while !Task.isCancelled {
                await refresh()
                let interval = RefreshPolicy.interval(
                    hasActiveSessions: !activeSessions.isEmpty,
                    lastPopoverOpen: lastPopoverOpen,
                    lowPowerMode: Foundation.ProcessInfo.processInfo.isLowPowerModeEnabled,
                    thermalState: Foundation.ProcessInfo.processInfo.thermalState
                )
                try? await Task.sleep(for: .seconds(interval))
            }
        }

        Task { await bridge.start() }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        resetBoundaryTask?.cancel()
        resetBoundaryTask = nil
        if let hookObserver { NotificationCenter.default.removeObserver(hookObserver) }
        hookObserver = nil
        if let activity { Foundation.ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        Task { await bridge.stop() }
    }

    /// Called when the popover becomes visible: bumps cadence and refreshes
    /// immediately (user-initiated fetches bypass the 429 gate).
    func popoverOpened() {
        lastPopoverOpen = Date()
        Task { await refresh(userInitiated: true) }
    }
```

`refresh` gains `userInitiated`, the scoped windows, backoff silence, reset-boundary scheduling, and the token scan:

```swift
    func refresh(userInitiated: Bool = false) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let usage = try await usageService.fetchUsage(userInitiated: userInitiated)
            fiveHourUtilization = usage.fiveHour?.utilization ?? 0
            fiveHourResetsAt = usage.fiveHour?.resetsAtDate
            weeklyUtilization = usage.sevenDay?.utilization ?? 0
            weeklyResetsAt = usage.sevenDay?.resetsAtDate
            opusUtilization = usage.sevenDayOpus?.utilization ?? 0
            scopedWindows = usage.scopedWindows()

            if let extra = usage.extraUsage, extra.isEnabled {
                extraUsageEnabled = true
                extraUsageUtilization = extra.utilization ?? 0
                extraUsageUsedDollars = Double(extra.usedCredits ?? 0) / 100
                extraUsageLimitDollars = Double(extra.monthlyLimit ?? 0) / 100
            } else {
                extraUsageEnabled = false
            }

            isConnected = true
            lastError = nil

            checkUsageMilestones()
            scheduleResetBoundaryRefresh(for: usage)

            await historyService.record(weekly: weeklyUtilization, fiveHour: fiveHourUtilization)
            usageHistory = await historyService.getReadings()
        } catch UsageError.backoff {
            // Gated (backoff/429 window) — keep previous data silently.
        } catch UsageError.rateLimited {
            if !isConnected {
                lastError = "Rate limited — retrying shortly"
            }
        } catch {
            isConnected = false
            lastError = error.localizedDescription
        }

        activeSessions = await sessionService.getActiveSessions()
        await bridge.updateWatchedSessions(activeSessions)
        tokenUsage = await tokenScanner.snapshot()
    }

    /// One-shot refresh just after the nearest window reset so bars drop to
    /// zero promptly instead of waiting out the poll interval.
    private func scheduleResetBoundaryRefresh(for usage: UsageResponse) {
        let boundaries = [usage.fiveHour?.resetsAtDate, usage.sevenDay?.resetsAtDate]
            .compactMap { $0 }
            .filter { $0 > Date() }
        guard let nearest = boundaries.min(), nearest != lastScheduledBoundary else { return }
        lastScheduledBoundary = nearest
        resetBoundaryTask?.cancel()
        resetBoundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(nearest.timeIntervalSinceNow + 2))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Debounced local token rescan on hook events (realtime updates while
    /// a session streams).
    private func scheduleTokenScan() {
        scanDebounce?.cancel()
        scanDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            tokenUsage = await tokenScanner.snapshot()
        }
    }
```

Delete the old `pollTimer` property and `Timer.scheduledTimer` block.

- [ ] **Step 3: Build + tests** — `cd Code && swift build && swift test 2>&1 | tail -3` → green.
- [ ] **Step 4: Commit** — `git commit -am "feat: adaptive polling, reset-boundary refresh, live token scans"`

---

### Task 10: TokenStatsCard + PopoverView integration

**Files:**
- Create: `Code/Claudio/Views/TokenStatsCard.swift`
- Modify: `Code/Claudio/Views/PopoverView.swift`

**Interfaces:**
- Consumes: `TokenUsageSnapshot`, `TokenCounts`, `compactTokens` (Task 3); `AppViewModel.tokenUsage`, `popoverOpened()` (Task 9)

- [ ] **Step 1: Implement `Code/Claudio/Views/TokenStatsCard.swift`** (matches UsageCard/SessionCard glass style):

```swift
import SwiftUI

struct TokenStatsCard: View {
    let usage: TokenUsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tokens Today")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                stat("In", usage.todayTotal.input)
                stat("Out", usage.todayTotal.output)
                stat("Cache W", usage.todayTotal.cacheCreate)
                stat("Cache R", usage.todayTotal.cacheRead)
            }

            if !usage.today.isEmpty {
                Divider()
                ForEach(sortedModels, id: \.0) { model, counts in
                    HStack {
                        Text(shortModelName(model))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(compactTokens(counts.total))
                            .font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private var sortedModels: [(String, TokenCounts)] {
        usage.today.sorted { $0.value.total > $1.value.total }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text(compactTokens(value))
                .font(.callout.monospacedDigit())
                .fontWeight(.medium)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func shortModelName(_ model: String) -> String {
        model
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }
}
```

- [ ] **Step 2: Integrate in `PopoverView.swift`.** In `mainView`'s `VStack`, after `chartSection`:

```swift
                        if viewModel.tokenUsage.todayTotal.total > 0 {
                            TokenStatsCard(usage: viewModel.tokenUsage)
                        }
                        if !viewModel.scopedWindows.isEmpty {
                            scopedWindowsSection
                        }
```

And add the section view (model-scoped promo/limit windows from `limits[]`):

```swift
    private var scopedWindowsSection: some View {
        VStack(spacing: 6) {
            ForEach(viewModel.scopedWindows, id: \.name) { window in
                HStack {
                    Text(window.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(window.utilization))%")
                        .font(.caption2.monospacedDigit())
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
```

And in the existing `.onChange(of: scenePhase)` (the outer one at line ~49), add the popover-open hook:

```swift
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                showSettings = false
                viewModel.popoverOpened()
            }
        }
```

Also update the footer Refresh button to be user-initiated:

```swift
            Button("Refresh") {
                Task { await viewModel.refresh(userInitiated: true) }
            }
```

- [ ] **Step 3: Build + tests** — green.
- [ ] **Step 4: Commit** — `git commit -am "feat: live token stats card in popover"`

---

### Task 11: End-to-end verification and deploy

**Files:** none (verification)

- [ ] **Step 1: Full build + tests** — `cd Code && swift build && swift test` → all pass.
- [ ] **Step 2: Debug bundle** — `cd Code && ./build.sh` → app at `.build/arm64-apple-macosx/debug/Claudio.app`.
- [ ] **Step 3: Deploy per memory workflow** — quit running Claudio (`osascript -e 'quit app "Claudio"'`), `rm -rf /Applications/Claudio.app && cp -R Code/.build/arm64-apple-macosx/debug/Claudio.app /Applications/`, `open /Applications/Claudio.app`.
- [ ] **Step 4: Verify live behavior:**
  - Menu bar percentage appears (API fetch worked; no keychain prompt).
  - Popover shows the Tokens Today card with non-zero counts (this very Claude Code session generates transcript lines — counts should grow across a refresh while the session streams).
  - `~/Library/Caches/Claudio/token-scan-v1.json` exists and second refresh is fast.
  - No repeated OAuth refresh requests in Console logs; `~/.claude/widget-credentials.json` untouched unless a refresh actually ran.
- [ ] **Step 5: Commit any fixups; final commit** — `git commit -am "fix: <whatever verification surfaced>"` (only if needed).
