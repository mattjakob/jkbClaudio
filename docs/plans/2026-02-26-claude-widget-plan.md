# ClaudeWidget Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a native macOS 26 menu bar app that monitors Claude Code usage (5-hour/weekly utilization) and active sessions with a Liquid Glass popover UI.

**Architecture:** SwiftUI `MenuBarExtra(.window)` with `@Observable` ViewModel. Three services (Keychain, Usage API, Session files) feed into a single ViewModel. Glass popover shows usage bars, active sessions, and weekly stats.

**Tech Stack:** Swift 6.2, SwiftUI (macOS 26), Security framework, URLSession async/await, FSEvents via DispatchSource

---

## Task 1: Create Xcode Project Scaffold

**Files:**
- Create: `ClaudeWidget/ClaudeWidgetApp.swift`
- Create: `ClaudeWidget/Info.plist`

**Step 1: Create the Swift Package / Xcode project**

```bash
cd /Users/mattjakob/Documents/Code/XCode/jkbClaudeWidget
mkdir -p ClaudeWidget
```

**Step 2: Create the app entry point**

Create `ClaudeWidget/ClaudeWidgetApp.swift`:

```swift
import SwiftUI

@main
struct ClaudeWidgetApp: App {
    var body: some Scene {
        MenuBarExtra {
            Text("ClaudeWidget placeholder")
                .frame(width: 320, height: 200)
                .padding()
        } label: {
            Label("Claude", systemImage: "terminal.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
```

**Step 3: Create Info.plist**

Create `ClaudeWidget/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
```

**Step 4: Create Package.swift**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClaudeWidget",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "ClaudeWidget",
            path: "ClaudeWidget",
            resources: [.process("Info.plist")]
        )
    ]
)
```

**Step 5: Build and verify menu bar icon appears**

```bash
swift build
swift run ClaudeWidget &
# Verify: terminal.fill icon appears in menu bar, clicking shows placeholder text
killall ClaudeWidget
```

**Step 6: Commit**

```bash
git init && git branch -M main
git add -A
git commit -m "feat: scaffold macOS 26 menu bar app with MenuBarExtra"
```

---

## Task 2: Models — Data Structures

**Files:**
- Create: `ClaudeWidget/Models/UsageData.swift`
- Create: `ClaudeWidget/Models/Session.swift`
- Create: `ClaudeWidget/Models/WeeklyStats.swift`

**Step 1: Create UsageData model**

Create `ClaudeWidget/Models/UsageData.swift`:

```swift
import Foundation

struct UsageWindow: Codable, Sendable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        return ISO8601DateFormatter().date(from: resetsAt)
    }
}

struct UsageResponse: Codable, Sendable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOauthApps: UsageWindow?
    let sevenDayOpus: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
    }
}

struct OAuthCredentials: Codable, Sendable {
    struct ClaudeAiOauth: Codable, Sendable {
        let accessToken: String
        let refreshToken: String
    }
    let claudeAiOauth: ClaudeAiOauth
}
```

**Step 2: Create Session model**

Create `ClaudeWidget/Models/Session.swift`:

```swift
import Foundation

struct SessionEntry: Codable, Identifiable, Sendable {
    let sessionId: String
    let fullPath: String
    let fileMtime: Int64
    let firstPrompt: String?
    let summary: String?
    let messageCount: Int
    let created: String
    let modified: String
    let gitBranch: String?
    let projectPath: String
    let isSidechain: Bool

    var id: String { sessionId }

    var createdDate: Date? {
        ISO8601DateFormatter().date(from: created)
    }

    var modifiedDate: Date? {
        ISO8601DateFormatter().date(from: modified)
    }

    var projectName: String {
        projectPath.components(separatedBy: "/").last ?? projectPath
    }
}

struct SessionsIndex: Codable, Sendable {
    let version: Int
    let entries: [SessionEntry]
}
```

**Step 3: Create WeeklyStats model**

Create `ClaudeWidget/Models/WeeklyStats.swift`:

```swift
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
```

**Step 4: Verify build**

```bash
swift build
```

**Step 5: Commit**

```bash
git add ClaudeWidget/Models/
git commit -m "feat: add data models for usage, sessions, and weekly stats"
```

---

## Task 3: KeychainService — OAuth Token Retrieval

**Files:**
- Create: `ClaudeWidget/Services/KeychainService.swift`

**Step 1: Implement KeychainService**

Create `ClaudeWidget/Services/KeychainService.swift`:

```swift
import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case itemNotFound
    case unexpectedData
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .itemNotFound: "Claude Code credentials not found in Keychain"
        case .unexpectedData: "Unexpected credential format"
        case .decodingFailed(let error): "Failed to decode credentials: \(error)"
        }
    }
}

struct KeychainService: Sendable {
    static let serviceName = "Claude Code-credentials"

    static func getCredentials() throws -> OAuthCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            throw KeychainError.itemNotFound
        }

        guard let data = result as? Data else {
            throw KeychainError.unexpectedData
        }

        do {
            return try JSONDecoder().decode(OAuthCredentials.self, from: data)
        } catch {
            throw KeychainError.decodingFailed(error)
        }
    }

    static func getAccessToken() throws -> String {
        try getCredentials().claudeAiOauth.accessToken
    }

    static func getRefreshToken() throws -> String {
        try getCredentials().claudeAiOauth.refreshToken
    }
}
```

**Step 2: Verify build**

```bash
swift build
```

**Step 3: Commit**

```bash
git add ClaudeWidget/Services/KeychainService.swift
git commit -m "feat: add KeychainService for OAuth token retrieval"
```

---

## Task 4: UsageService — API Polling

**Files:**
- Create: `ClaudeWidget/Services/UsageService.swift`

**Step 1: Implement UsageService**

Create `ClaudeWidget/Services/UsageService.swift`:

```swift
import Foundation

actor UsageService {
    private let apiURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let refreshURL = URL(string: "https://console.anthropic.com/api/oauth/token")!
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    func fetchUsage() async throws -> UsageResponse {
        let token = try KeychainService.getAccessToken()
        return try await request(with: token)
    }

    private func request(with token: String) async throws -> UsageResponse {
        var request = URLRequest(url: apiURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClaudeWidget/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if http.statusCode == 401 {
            let newToken = try await refreshAccessToken()
            return try await request(with: newToken)
        }

        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    private func refreshAccessToken() async throws -> String {
        let refreshToken = try KeychainService.getRefreshToken()

        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }

        struct RefreshResponse: Codable {
            let access_token: String
        }

        let refreshResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)
        return refreshResponse.access_token
    }
}
```

**Step 2: Verify build**

```bash
swift build
```

**Step 3: Commit**

```bash
git add ClaudeWidget/Services/UsageService.swift
git commit -m "feat: add UsageService with OAuth polling and token refresh"
```

---

## Task 5: SessionService — Local File Monitoring

**Files:**
- Create: `ClaudeWidget/Services/SessionService.swift`

**Step 1: Implement SessionService**

Create `ClaudeWidget/Services/SessionService.swift`:

```swift
import Foundation

actor SessionService {
    private let claudeDir: String
    private let projectsDir: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.claudeDir = "\(home)/.claude"
        self.projectsDir = "\(home)/.claude/projects"
    }

    func getActiveSessions() -> [SessionEntry] {
        let activePIDs = getClaudeProcessSessionIds()
        let allSessions = loadAllSessions()

        let cutoff = Date().addingTimeInterval(-3600) // last hour
        return allSessions.filter { session in
            let isRunning = activePIDs.contains(session.sessionId)
            let isRecent = session.modifiedDate.map { $0 > cutoff } ?? false
            return isRunning || isRecent
        }
        .sorted { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
    }

    func getWeeklyStats() -> WeeklyStats {
        guard let cache = loadStatsCache() else { return WeeklyStats() }

        let calendar = Calendar.current
        let now = Date()
        guard let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) else {
            return WeeklyStats()
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let weekStartStr = dateFormatter.string(from: weekStart)

        let weeklyActivity = cache.dailyActivity.filter { $0.date >= weekStartStr }
        let sessions = weeklyActivity.reduce(0) { $0 + $1.sessionCount }
        let messages = weeklyActivity.reduce(0) { $0 + $1.messageCount }

        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        for (_, usage) in cache.modelUsage {
            inputTokens += usage.inputTokens
            outputTokens += usage.outputTokens
        }

        return WeeklyStats(
            sessions: sessions,
            messages: messages,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            dailyActivity: weeklyActivity
        )
    }

    private func loadAllSessions() -> [SessionEntry] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }

        var sessions: [SessionEntry] = []
        for dir in projectDirs {
            let indexPath = "\(projectsDir)/\(dir)/sessions-index.json"
            guard let data = fm.contents(atPath: indexPath) else { continue }
            guard let index = try? JSONDecoder().decode(SessionsIndex.self, from: data) else { continue }
            sessions.append(contentsOf: index.entries)
        }
        return sessions
    }

    private func loadStatsCache() -> StatsCache? {
        let path = "\(claudeDir)/stats-cache.json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(StatsCache.self, from: data)
    }

    private func getClaudeProcessSessionIds() -> Set<String> {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fl", "claude"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        var sessionIds = Set<String>()
        for line in output.components(separatedBy: "\n") {
            if let range = line.range(of: "--session-id\\s+([a-f0-9-]+)", options: .regularExpression) {
                let match = line[range]
                if let idRange = match.range(of: "[a-f0-9-]{36}", options: .regularExpression) {
                    sessionIds.insert(String(match[idRange]))
                }
            }
        }
        return sessionIds
    }
}
```

**Step 2: Verify build**

```bash
swift build
```

**Step 3: Commit**

```bash
git add ClaudeWidget/Services/SessionService.swift
git commit -m "feat: add SessionService for local file monitoring and process detection"
```

---

## Task 6: AppViewModel — Observable State

**Files:**
- Create: `ClaudeWidget/ViewModel/AppViewModel.swift`

**Step 1: Implement AppViewModel**

Create `ClaudeWidget/ViewModel/AppViewModel.swift`:

```swift
import Foundation
import SwiftUI

@Observable
@MainActor
final class AppViewModel {
    var fiveHourUtilization: Double = 0
    var fiveHourResetsAt: Date?
    var weeklyUtilization: Double = 0
    var weeklyResetsAt: Date?
    var opusUtilization: Double = 0

    var activeSessions: [SessionEntry] = []
    var weeklyStats = WeeklyStats()

    var isConnected = false
    var lastError: String?
    var isLoading = false

    private let usageService = UsageService()
    private let sessionService = SessionService()
    private var pollTimer: Timer?

    var menuBarText: String {
        if !isConnected { return "" }
        return "\(Int(weeklyUtilization))%"
    }

    var menuBarColor: Color {
        if weeklyUtilization >= 80 { return .red }
        if weeklyUtilization >= 60 { return .yellow }
        return .white
    }

    func startPolling() {
        Task { await refresh() }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refresh() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        // Fetch usage from API
        do {
            let usage = try await usageService.fetchUsage()
            fiveHourUtilization = usage.fiveHour?.utilization ?? 0
            fiveHourResetsAt = usage.fiveHour?.resetsAtDate
            weeklyUtilization = usage.sevenDay?.utilization ?? 0
            weeklyResetsAt = usage.sevenDay?.resetsAtDate
            opusUtilization = usage.sevenDayOpus?.utilization ?? 0
            isConnected = true
            lastError = nil
        } catch {
            isConnected = false
            lastError = error.localizedDescription
        }

        // Fetch local session data
        activeSessions = await sessionService.getActiveSessions()
        weeklyStats = await sessionService.getWeeklyStats()
    }
}
```

**Step 2: Verify build**

```bash
swift build
```

**Step 3: Commit**

```bash
git add ClaudeWidget/ViewModel/AppViewModel.swift
git commit -m "feat: add AppViewModel with polling and state management"
```

---

## Task 7: MenuBarLabel View

**Files:**
- Create: `ClaudeWidget/Views/MenuBarLabel.swift`
- Modify: `ClaudeWidget/ClaudeWidgetApp.swift`

**Step 1: Create MenuBarLabel**

Create `ClaudeWidget/Views/MenuBarLabel.swift`:

```swift
import SwiftUI

struct MenuBarLabel: View {
    let utilization: Double
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal.fill")
            if isConnected {
                Text("\(Int(utilization))%")
                    .font(.caption2)
                    .monospacedDigit()
            }
        }
    }
}
```

**Step 2: Update ClaudeWidgetApp to use ViewModel and MenuBarLabel**

Replace `ClaudeWidget/ClaudeWidgetApp.swift`:

```swift
import SwiftUI

@main
struct ClaudeWidgetApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(viewModel: viewModel)
                .frame(width: 320, height: 520)
        } label: {
            MenuBarLabel(
                utilization: viewModel.weeklyUtilization,
                isConnected: viewModel.isConnected
            )
        }
        .menuBarExtraStyle(.window)
    }
}
```

**Step 3: Create placeholder PopoverView** (so it builds)

Create `ClaudeWidget/Views/PopoverView.swift`:

```swift
import SwiftUI

struct PopoverView: View {
    let viewModel: AppViewModel

    var body: some View {
        VStack {
            Text("Loading...")
        }
        .task {
            viewModel.startPolling()
        }
    }
}
```

**Step 4: Verify build**

```bash
swift build
```

**Step 5: Commit**

```bash
git add ClaudeWidget/Views/ ClaudeWidget/ClaudeWidgetApp.swift
git commit -m "feat: add MenuBarLabel with utilization percentage display"
```

---

## Task 8: UsageCard View — Glass Utilization Bars

**Files:**
- Create: `ClaudeWidget/Views/UsageCard.swift`

**Step 1: Implement UsageCard**

Create `ClaudeWidget/Views/UsageCard.swift`:

```swift
import SwiftUI

struct UsageBar: View {
    let label: String
    let utilization: Double
    let resetsAt: Date?

    private var barColor: Color {
        if utilization >= 80 { return .red }
        if utilization >= 60 { return .yellow }
        return .white
    }

    private var resetText: String {
        guard let resetsAt else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: resetsAt, relativeTo: .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(utilization))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(barColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.1))
                        .frame(height: 6)

                    Capsule()
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * utilization / 100), height: 6)
                }
            }
            .frame(height: 6)

            HStack {
                Text("Resets")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct UsageCard: View {
    let fiveHourUtilization: Double
    let fiveHourResetsAt: Date?
    let weeklyUtilization: Double
    let weeklyResetsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Usage")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            UsageBar(
                label: "5-Hour",
                utilization: fiveHourUtilization,
                resetsAt: fiveHourResetsAt
            )

            UsageBar(
                label: "Weekly",
                utilization: weeklyUtilization,
                resetsAt: weeklyResetsAt
            )
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
```

**Step 2: Verify build**

```bash
swift build
```

**Step 3: Commit**

```bash
git add ClaudeWidget/Views/UsageCard.swift
git commit -m "feat: add UsageCard with glass utilization bars"
```

---

## Task 9: SessionCard View — Active Sessions

**Files:**
- Create: `ClaudeWidget/Views/SessionCard.swift`

**Step 1: Implement SessionCard**

Create `ClaudeWidget/Views/SessionCard.swift`:

```swift
import SwiftUI

struct SessionRow: View {
    let session: SessionEntry
    let isActive: Bool

    private var timeAgo: String {
        guard let modified = session.modifiedDate else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: modified, relativeTo: .now)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isActive ? .green : .gray.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.projectName)
                        .font(.callout)
                        .fontWeight(.medium)
                    if !isActive {
                        Text("idle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: 8) {
                    if let branch = session.gitBranch {
                        Text(branch)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(session.messageCount) msgs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(timeAgo)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
    }
}

struct SessionCard: View {
    let sessions: [SessionEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active Sessions")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            if sessions.isEmpty {
                Text("No recent sessions")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ForEach(sessions.prefix(5)) { session in
                    SessionRow(
                        session: session,
                        isActive: session.modifiedDate.map { $0.timeIntervalSinceNow > -300 } ?? false
                    )
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
```

**Step 2: Verify build**

```bash
swift build
```

**Step 3: Commit**

```bash
git add ClaudeWidget/Views/SessionCard.swift
git commit -m "feat: add SessionCard with active/idle session indicators"
```

---

## Task 10: StatsCard View — Weekly Summary

**Files:**
- Create: `ClaudeWidget/Views/StatsCard.swift`

**Step 1: Implement StatsCard**

Create `ClaudeWidget/Views/StatsCard.swift`:

```swift
import SwiftUI

struct SparklineView: View {
    let values: [Int]

    var body: some View {
        GeometryReader { geo in
            let maxVal = Double(values.max() ?? 1)
            let step = geo.size.width / Double(max(values.count - 1, 1))

            Path { path in
                for (index, value) in values.enumerated() {
                    let x = Double(index) * step
                    let y = geo.size.height - (Double(value) / maxVal * geo.size.height)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(.white.opacity(0.6), lineWidth: 1.5)
        }
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .monospacedDigit()
        }
    }
}

struct StatsCard: View {
    let stats: WeeklyStats

    private func formatTokens(_ count: Int64) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Week")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            StatRow(label: "Sessions", value: "\(stats.sessions)")
            StatRow(label: "Messages", value: stats.messages.formatted())
            StatRow(
                label: "Tokens",
                value: "\(formatTokens(stats.inputTokens)) in / \(formatTokens(stats.outputTokens)) out"
            )

            if !stats.dailyActivity.isEmpty {
                SparklineView(values: stats.dailyActivity.map(\.messageCount))
                    .frame(height: 30)
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
```

**Step 2: Verify build**

```bash
swift build
```

**Step 3: Commit**

```bash
git add ClaudeWidget/Views/StatsCard.swift
git commit -m "feat: add StatsCard with weekly summary and sparkline"
```

---

## Task 11: PopoverView — Full Glass Layout

**Files:**
- Modify: `ClaudeWidget/Views/PopoverView.swift`

**Step 1: Implement full PopoverView**

Replace `ClaudeWidget/Views/PopoverView.swift`:

```swift
import SwiftUI

struct PopoverView: View {
    let viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                headerSection
                usageSection
                sessionsSection
                statsSection
                footerSection
            }
            .padding(16)
        }
        .task {
            viewModel.startPolling()
        }
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("CLAUDE CODE")
                    .font(.caption)
                    .fontWeight(.bold)
                    .tracking(1.5)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isConnected ? .green : .red)
                        .frame(width: 6, height: 6)
                    Text(viewModel.isConnected ? "Connected" : "Disconnected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if viewModel.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private var usageSection: some View {
        UsageCard(
            fiveHourUtilization: viewModel.fiveHourUtilization,
            fiveHourResetsAt: viewModel.fiveHourResetsAt,
            weeklyUtilization: viewModel.weeklyUtilization,
            weeklyResetsAt: viewModel.weeklyResetsAt
        )
    }

    private var sessionsSection: some View {
        SessionCard(sessions: viewModel.activeSessions)
    }

    private var statsSection: some View {
        StatsCard(stats: viewModel.weeklyStats)
    }

    private var footerSection: some View {
        HStack {
            Button("Refresh") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.glass)
            .controlSize(.small)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }
}
```

**Step 2: Verify build and run**

```bash
swift build
swift run ClaudeWidget &
# Verify: click menu bar icon, popover opens with glass cards
killall ClaudeWidget
```

**Step 3: Commit**

```bash
git add ClaudeWidget/Views/PopoverView.swift
git commit -m "feat: assemble PopoverView with glass layout and all card sections"
```

---

## Task 12: OTelReceiver — Optional Telemetry Server

**Files:**
- Create: `ClaudeWidget/Services/OTelReceiver.swift`

**Step 1: Implement lightweight OTel receiver**

Create `ClaudeWidget/Services/OTelReceiver.swift`:

```swift
import Foundation
import Network

actor OTelReceiver {
    private var listener: NWListener?
    private(set) var lastMetrics: [String: Double] = [:]
    var isRunning: Bool { listener != nil }

    func start(port: UInt16 = 4318) throws {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.handleConnection(connection)
        }

        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("OTel listener failed: \(error)")
            }
        }

        listener.start(queue: .global())
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private nonisolated func handleConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let data, let self else { return }
            Task { await self.processData(data) }
            self.handleConnection(connection)
        }
    }

    private func processData(_ data: Data) {
        // Parse OTLP JSON metrics payload
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resourceMetrics = json["resourceMetrics"] as? [[String: Any]] else {
            return
        }

        for rm in resourceMetrics {
            guard let scopeMetrics = rm["scopeMetrics"] as? [[String: Any]] else { continue }
            for sm in scopeMetrics {
                guard let metrics = sm["metrics"] as? [[String: Any]] else { continue }
                for metric in metrics {
                    guard let name = metric["name"] as? String else { continue }
                    // Extract the latest data point value
                    if let gauge = metric["gauge"] as? [String: Any],
                       let dataPoints = gauge["dataPoints"] as? [[String: Any]],
                       let last = dataPoints.last,
                       let value = last["asDouble"] as? Double {
                        lastMetrics[name] = value
                    }
                    if let sum = metric["sum"] as? [String: Any],
                       let dataPoints = sum["dataPoints"] as? [[String: Any]],
                       let last = dataPoints.last,
                       let value = last["asDouble"] as? Double {
                        lastMetrics[name] = value
                    }
                }
            }
        }
    }
}
```

**Step 2: Verify build**

```bash
swift build
```

**Step 3: Commit**

```bash
git add ClaudeWidget/Services/OTelReceiver.swift
git commit -m "feat: add optional OTelReceiver for real-time telemetry metrics"
```

---

## Task 13: Wire OTel into ViewModel and Polish

**Files:**
- Modify: `ClaudeWidget/ViewModel/AppViewModel.swift`

**Step 1: Add OTel integration to AppViewModel**

Update `ClaudeWidget/ViewModel/AppViewModel.swift` — add OTel receiver field and integrate into refresh:

Add after `private let sessionService = SessionService()`:

```swift
    private let otelReceiver = OTelReceiver()
    var otelConnected = false
```

Add to the end of `startPolling()`, before the closing brace:

```swift
        Task {
            do {
                try await otelReceiver.start()
                otelConnected = true
            } catch {
                otelConnected = false
            }
        }
```

Add to `stopPolling()`, before the closing brace:

```swift
        Task { await otelReceiver.stop() }
```

**Step 2: Verify build and full integration test**

```bash
swift build
swift run ClaudeWidget &
# Manual test:
# 1. Verify menu bar shows terminal icon + percentage
# 2. Click icon — popover opens with glass cards
# 3. Usage bars show 5-hour and weekly percentages
# 4. Active sessions list shows recent sessions
# 5. Weekly stats show aggregated numbers
# 6. Refresh button works
# 7. Quit button terminates app
killall ClaudeWidget
```

**Step 3: Commit**

```bash
git add ClaudeWidget/ViewModel/AppViewModel.swift
git commit -m "feat: integrate OTel receiver into ViewModel"
```

---

## Task 14: Final Polish — Entitlements and Launch

**Files:**
- Create: `ClaudeWidget/ClaudeWidget.entitlements`
- Create: `.gitignore`

**Step 1: Create entitlements for network access**

Create `ClaudeWidget/ClaudeWidget.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>keychain-access-groups</key>
    <array>
        <string>$(AppIdentifierPrefix)com.mattjakob.ClaudeWidget</string>
    </array>
</dict>
</plist>
```

**Step 2: Create .gitignore**

Create `.gitignore`:

```
.DS_Store
.build/
.swiftpm/
*.xcodeproj/
*.xcworkspace/
DerivedData/
```

**Step 3: Final build and run**

```bash
cd /Users/mattjakob/Documents/Code/XCode/jkbClaudeWidget
swift build
swift run ClaudeWidget
```

**Step 4: Commit**

```bash
git add .gitignore ClaudeWidget/ClaudeWidget.entitlements
git commit -m "chore: add entitlements and gitignore"
```
