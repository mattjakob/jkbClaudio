# Telegram Bridge Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Two-way messaging bridge between Claude Code agents and Telegram, built into Claudio.

**Architecture:** 6 new services (TelegramService, HookServer, SessionWatcher, RemoteSessionManager, StdinInjector, BridgeCoordinator) + 2 model files + 1 settings view. All integrated into the existing Claudio menu bar app. No external dependencies — raw URLSession for Telegram API, NWListener for HTTP server, DispatchSource for file watching.

**Tech Stack:** Swift 6.2, macOS 26, SwiftUI, Network.framework, Foundation

**Base path:** `/Users/mattjakob/Documents/Code/XCode/jkbClaudio/Code/Claudio`

---

### Task 1: Telegram API Models

**Files:**
- Create: `Models/TelegramModels.swift`

**Step 1: Create TelegramModels.swift**

All Codable types for the Telegram Bot API. Use `snake_case` coding keys since the API uses snake_case.

```swift
import Foundation

// MARK: - Incoming

struct TGUpdate: Codable, Sendable {
    let updateId: Int
    let message: TGMessage?
    let callbackQuery: TGCallbackQuery?

    enum CodingKeys: String, CodingKey {
        case updateId = "update_id"
        case message
        case callbackQuery = "callback_query"
    }
}

struct TGMessage: Codable, Sendable {
    let messageId: Int
    let from: TGUser?
    let chat: TGChat
    let text: String?
    let date: Int

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case from, chat, text, date
    }
}

struct TGCallbackQuery: Codable, Sendable {
    let id: String
    let from: TGUser
    let message: TGMessage?
    let data: String?
}

struct TGUser: Codable, Sendable {
    let id: Int
    let firstName: String
    let isBot: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case isBot = "is_bot"
    }
}

struct TGChat: Codable, Sendable {
    let id: Int
    let type: String
}

// MARK: - Outgoing

struct TGSendMessage: Codable, Sendable {
    let chatId: Int
    let text: String
    let parseMode: String?
    let replyMarkup: TGInlineKeyboardMarkup?

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case text
        case parseMode = "parse_mode"
        case replyMarkup = "reply_markup"
    }
}

struct TGInlineKeyboardMarkup: Codable, Sendable {
    let inlineKeyboard: [[TGInlineKeyboardButton]]

    enum CodingKeys: String, CodingKey {
        case inlineKeyboard = "inline_keyboard"
    }
}

struct TGInlineKeyboardButton: Codable, Sendable {
    let text: String
    let callbackData: String?

    enum CodingKeys: String, CodingKey {
        case text
        case callbackData = "callback_data"
    }
}

struct TGEditMessageReplyMarkup: Codable, Sendable {
    let chatId: Int
    let messageId: Int
    let replyMarkup: TGInlineKeyboardMarkup?

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case messageId = "message_id"
        case replyMarkup = "reply_markup"
    }
}

// MARK: - API Response

struct TGResponse<T: Codable & Sendable>: Codable, Sendable {
    let ok: Bool
    let result: T?
    let description: String?
}
```

**Step 2: Commit**

```bash
git add Code/Claudio/Models/TelegramModels.swift
git commit -m "feat: add Telegram Bot API Codable models"
```

---

### Task 2: Hook Event Models

**Files:**
- Create: `Models/HookEvent.swift`

**Step 1: Create HookEvent.swift**

Models for Claude Code hook JSON received on stdin. Based on the hooks API documentation.

```swift
import Foundation

struct HookEvent: Codable, Sendable {
    let sessionId: String?
    let transcriptPath: String?
    let cwd: String?
    let permissionMode: String?
    let hookEventName: String

    // PermissionRequest fields
    let toolName: String?
    let toolInput: [String: AnyCodable]?

    // Notification fields
    let message: String?
    let title: String?
    let notificationType: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case permissionMode = "permission_mode"
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case message, title
        case notificationType = "notification_type"
    }
}

/// Type-erased Codable wrapper for arbitrary JSON values in hook payloads.
struct AnyCodable: Codable, Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) { value = str }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let dict = try? container.decode([String: AnyCodable].self) { value = dict }
        else if let arr = try? container.decode([AnyCodable].self) { value = arr }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let str as String: try container.encode(str)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let bool as Bool: try container.encode(bool)
        case let dict as [String: AnyCodable]: try container.encode(dict)
        case let arr as [AnyCodable]: try container.encode(arr)
        default: try container.encodeNil()
        }
    }

    var stringValue: String? { value as? String }
}

/// Hook response for PermissionRequest — returned as HTTP body to the waiting curl.
struct HookPermissionResponse: Codable, Sendable {
    struct Decision: Codable, Sendable {
        let behavior: String  // "allow" or "deny"
        let message: String?
    }
    struct SpecificOutput: Codable, Sendable {
        let hookEventName: String
        let decision: Decision
    }
    let hookSpecificOutput: SpecificOutput

    static func allow() -> HookPermissionResponse {
        HookPermissionResponse(hookSpecificOutput: SpecificOutput(
            hookEventName: "PermissionRequest",
            decision: Decision(behavior: "allow", message: nil)
        ))
    }

    static func deny(message: String? = nil) -> HookPermissionResponse {
        HookPermissionResponse(hookSpecificOutput: SpecificOutput(
            hookEventName: "PermissionRequest",
            decision: Decision(behavior: "deny", message: message ?? "Denied via Claudio")
        ))
    }
}
```

**Step 2: Commit**

```bash
git add Code/Claudio/Models/HookEvent.swift
git commit -m "feat: add Claude Code hook event models"
```

---

### Task 3: TelegramService

**Files:**
- Create: `Services/TelegramService.swift`

**Step 1: Create TelegramService.swift**

Actor-based Telegram Bot API client using raw URLSession. Handles long polling, sending messages, inline keyboards, and callback queries.

```swift
import Foundation

actor TelegramService {
    private let token: String
    private let baseURL: URL
    private let session: URLSession
    private var offset: Int = 0
    private var pollingTask: Task<Void, Never>?
    private(set) var chatId: Int?

    init(token: String) {
        self.token = token
        self.baseURL = URL(string: "https://api.telegram.org/bot\(token)/")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 35
        self.session = URLSession(configuration: config)
    }

    var isConfigured: Bool { !token.isEmpty }

    func setChatId(_ id: Int) {
        self.chatId = id
    }

    // MARK: - Polling

    func startPolling(handler: @escaping @Sendable (TGUpdate) async -> Void) {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let updates = try await self.getUpdates(timeout: 30)
                    for update in updates {
                        await self.setOffset(update.updateId + 1)
                        await handler(update)
                    }
                } catch {
                    if !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func setOffset(_ value: Int) {
        offset = value
    }

    // MARK: - API Methods

    func getUpdates(timeout: Int = 30) async throws -> [TGUpdate] {
        struct Params: Codable {
            let offset: Int
            let timeout: Int
            let allowedUpdates: [String]
            enum CodingKeys: String, CodingKey {
                case offset, timeout
                case allowedUpdates = "allowed_updates"
            }
        }
        let params = Params(offset: offset, timeout: timeout, allowedUpdates: ["message", "callback_query"])
        let response: TGResponse<[TGUpdate]> = try await post("getUpdates", body: params)
        return response.result ?? []
    }

    @discardableResult
    func sendMessage(
        chatId: Int,
        text: String,
        parseMode: String? = nil,
        replyMarkup: TGInlineKeyboardMarkup? = nil
    ) async throws -> TGMessage {
        let body = TGSendMessage(chatId: chatId, text: text, parseMode: parseMode, replyMarkup: replyMarkup)
        let response: TGResponse<TGMessage> = try await post("sendMessage", body: body)
        guard let result = response.result else {
            throw URLError(.badServerResponse)
        }
        return result
    }

    func answerCallbackQuery(id: String, text: String? = nil) async throws {
        struct Params: Codable {
            let callbackQueryId: String
            let text: String?
            enum CodingKeys: String, CodingKey {
                case callbackQueryId = "callback_query_id"
                case text
            }
        }
        let _: TGResponse<Bool> = try await post("answerCallbackQuery", body: Params(callbackQueryId: id, text: text))
    }

    func editMessageReplyMarkup(chatId: Int, messageId: Int) async throws {
        let body = TGEditMessageReplyMarkup(chatId: chatId, messageId: messageId, replyMarkup: nil)
        let _: TGResponse<TGMessage> = try await post("editMessageReplyMarkup", body: body)
    }

    // MARK: - Convenience

    func send(_ text: String, replyMarkup: TGInlineKeyboardMarkup? = nil) async {
        guard let chatId else { return }
        let truncated = text.count > 4000 ? String(text.prefix(4000)) + "..." : text
        try? await sendMessage(chatId: chatId, text: truncated, parseMode: "HTML", replyMarkup: replyMarkup)
    }

    // MARK: - HTTP

    private func post<B: Encodable, R: Decodable>(_ method: String, body: B) async throws -> R {
        let url = baseURL.appendingPathComponent(method)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(R.self, from: data)
    }
}
```

**Step 2: Verify it compiles**

Build the project in Xcode or via `swift build` from `Code/`. Fix any Swift 6 concurrency issues if they arise.

**Step 3: Commit**

```bash
git add Code/Claudio/Services/TelegramService.swift
git commit -m "feat: add Telegram Bot API client service"
```

---

### Task 4: HookServer

**Files:**
- Create: `Services/HookServer.swift`

**Step 1: Create HookServer.swift**

Local HTTP server using NWListener (Network.framework) on port 19876. Receives Claude Code hook events via curl. For PermissionRequest, holds the connection open using a CheckedContinuation until the Telegram user responds.

```swift
import Foundation
import Network

actor HookServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let port: UInt16 = 19876
    var onEvent: (@Sendable (HookEvent, String) async -> Void)?

    // Pending permission requests: hookId -> continuation that sends HTTP response
    private var pendingPermissions: [String: CheckedContinuation<HookPermissionResponse, Never>] = [:]
    private var nextPermissionId: Int = 0

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw URLError(.badURL)
        }
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            Task { await self?.handleConnection(connection) }
        }

        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { await self?.stop() }
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for conn in connections { conn.cancel() }
        connections.removeAll()
        for (_, cont) in pendingPermissions {
            cont.resume(returning: .deny(message: "Server stopped"))
        }
        pendingPermissions.removeAll()
    }

    /// Called by BridgeCoordinator when user taps Approve/Deny in Telegram.
    func resolvePermission(id: String, allow: Bool) {
        guard let cont = pendingPermissions.removeValue(forKey: id) else { return }
        cont.resume(returning: allow ? .allow() : .deny())
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        readRequest(connection)
    }

    private nonisolated func readRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data else {
                connection.cancel()
                return
            }
            Task { await self.processRequest(data, connection: connection) }
        }
    }

    private func processRequest(_ data: Data, connection: NWConnection) async {
        // Parse HTTP request to extract body (after \r\n\r\n)
        let raw = String(data: data, encoding: .utf8) ?? ""
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let body = parts.count > 1 ? parts[1] : raw
        let path = extractPath(from: raw)

        guard let bodyData = body.data(using: .utf8),
              let event = try? JSONDecoder().decode(HookEvent.self, from: bodyData) else {
            sendResponse(connection, status: 400, body: "Bad request")
            return
        }

        if path.contains("/hook/permission") {
            let permId = "perm_\(nextPermissionId)"
            nextPermissionId += 1

            // Notify coordinator (which will forward to Telegram)
            await onEvent?(event, permId)

            // Block until Telegram user responds (up to 110s, leaving margin for hook 120s timeout)
            let response = await withCheckedContinuation { (cont: CheckedContinuation<HookPermissionResponse, Never>) in
                pendingPermissions[permId] = cont

                // Auto-timeout after 110 seconds
                Task {
                    try? await Task.sleep(for: .seconds(110))
                    if let c = pendingPermissions.removeValue(forKey: permId) {
                        c.resume(returning: .deny(message: "Timed out waiting for Telegram response"))
                    }
                }
            }

            let responseData = (try? JSONEncoder().encode(response)) ?? Data()
            sendResponse(connection, status: 200, body: String(data: responseData, encoding: .utf8) ?? "{}")
        } else {
            // Non-blocking events: notification, stop, session-start, session-end
            await onEvent?(event, "")
            sendResponse(connection, status: 200, body: "{}")
        }
    }

    private func extractPath(from request: String) -> String {
        // Extract path from "POST /hook/permission HTTP/1.1"
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        return parts.count > 1 ? parts[1] : ""
    }

    private nonisolated func sendResponse(_ connection: NWConnection, status: Int, body: String) {
        let statusText = status == 200 ? "OK" : "Bad Request"
        let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
    }
}
```

**Step 2: Verify it compiles**

Build the project. Ensure NWListener and async continuations work with Swift 6 strict concurrency.

**Step 3: Commit**

```bash
git add Code/Claudio/Services/HookServer.swift
git commit -m "feat: add local HTTP hook server for Claude Code events"
```

---

### Task 5: SessionWatcher

**Files:**
- Create: `Services/SessionWatcher.swift`

**Step 1: Create SessionWatcher.swift**

DispatchSource-based file monitor. Watches JSONL files for new appended lines and delivers them via AsyncStream.

```swift
import Foundation

struct WatchedLine: Sendable {
    let sessionPath: String
    let jsonLine: Data
}

actor SessionWatcher {
    private var watchers: [String: FileWatchState] = []
    var onNewLine: (@Sendable (WatchedLine) async -> Void)?

    private struct FileWatchState {
        let source: DispatchSource
        let fileHandle: FileHandle
        let fd: Int32
    }

    func watchFile(at path: String) {
        guard watchers[path] == nil else { return }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let fileHandle = FileHandle(fileDescriptor: fd, closeOnDedaloc: false)
        // Seek to end — only want new data
        fileHandle.seekToEndOfFile()

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.extend, .write, .delete, .rename],
            queue: DispatchQueue.global(qos: .userInitiated)
        ) as! DispatchSource

        let handler = onNewLine
        let watchedPath = path
        (source as DispatchSourceFileSystemObject).setEventHandler { [weak self] in
            let event = (source as DispatchSourceFileSystemObject).data
            if event.contains(.delete) || event.contains(.rename) {
                Task { await self?.unwatchFile(at: watchedPath) }
                return
            }
            if event.contains(.extend) || event.contains(.write) {
                let newData = fileHandle.availableData
                guard !newData.isEmpty else { return }
                let lines = newData.split(separator: UInt8(ascii: "\n"))
                for line in lines {
                    let lineData = Data(line)
                    Task { await handler?(WatchedLine(sessionPath: watchedPath, jsonLine: lineData)) }
                }
            }
        }

        (source as DispatchSourceFileSystemObject).setCancelHandler {
            try? fileHandle.close()
            close(fd)
        }

        source.resume()
        watchers[path] = FileWatchState(source: source, fileHandle: fileHandle, fd: fd)
    }

    func unwatchFile(at path: String) {
        guard let state = watchers.removeValue(forKey: path) else { return }
        state.source.cancel()
    }

    func unwatchAll() {
        for (_, state) in watchers {
            state.source.cancel()
        }
        watchers.removeAll()
    }

    var watchedPaths: Set<String> {
        Set(watchers.keys)
    }
}
```

**Note:** The `DispatchSource` casting pattern above may need adjustment during implementation. The key API is `DispatchSource.makeFileSystemObjectSource(fileDescriptor:eventMask:queue:)` which returns a `DispatchSourceFileSystemObject`. Use the actual return type directly. The implementer should verify the exact API surface.

**Step 2: Verify it compiles**

Build the project. Fix any DispatchSource API issues — the exact Swift 6 API for `setEventHandler`/`setCancelHandler` may need adjustment.

**Step 3: Commit**

```bash
git add Code/Claudio/Services/SessionWatcher.swift
git commit -m "feat: add DispatchSource JSONL file watcher"
```

---

### Task 6: StdinInjector

**Files:**
- Create: `Services/StdinInjector.swift`

**Step 1: Create StdinInjector.swift**

Best-effort keystroke injection into terminal sessions. Tries tmux first, then Terminal.app, then iTerm2.

```swift
import Foundation

enum StdinInjector {
    enum InjectionResult: Sendable {
        case success
        case failed(String)
    }

    /// Attempt to inject text into the terminal session running the given PID.
    static func inject(text: String, forPid pid: String) async -> InjectionResult {
        // 1. Try tmux
        if let pane = findTmuxPane(pid: pid) {
            return runShell("/usr/bin/env", args: ["tmux", "send-keys", "-t", pane, text, "Enter"])
        }

        // 2. Try Terminal.app via AppleScript
        let terminalScript = """
        tell application "System Events"
            if exists process "Terminal" then
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if processes of t contains "\(pid)" then
                                do script "\(escaped(text))" in t
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end tell
            end if
        end tell
        return "not_found"
        """
        let termResult = runAppleScript(terminalScript)
        if termResult == .success { return .success }

        // 3. Try iTerm2 via AppleScript
        let itermScript = """
        tell application "System Events"
            if exists process "iTerm2" then
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s contains "\(pid)" then
                                    write text "\(escaped(text))" to s
                                    return "ok"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
            end if
        end tell
        return "not_found"
        """
        let itermResult = runAppleScript(itermScript)
        if itermResult == .success { return .success }

        return .failed("Could not find terminal for PID \(pid). Use a remote session instead.")
    }

    private static func findTmuxPane(pid: String) -> String? {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["tmux", "list-panes", "-a", "-F", "#{pane_id} #{pane_pid}"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: " ")
            if parts.count >= 2, parts[1] == pid {
                return parts[0]
            }
        }
        return nil
    }

    private static func runShell(_ executable: String, args: [String]) -> InjectionResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return .failed(error.localizedDescription) }
        return proc.terminationStatus == 0 ? .success : .failed("exit \(proc.terminationStatus)")
    }

    private static func runAppleScript(_ script: String) -> InjectionResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return .failed(error.localizedDescription) }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output == "ok" ? .success : .failed("not found")
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
```

**Step 2: Commit**

```bash
git add Code/Claudio/Services/StdinInjector.swift
git commit -m "feat: add best-effort terminal stdin injection"
```

---

### Task 7: RemoteSessionManager

**Files:**
- Create: `Services/RemoteSessionManager.swift`

**Step 1: Create RemoteSessionManager.swift**

Spawns and manages Claude Code subprocesses for remote Telegram sessions.

```swift
import Foundation

actor RemoteSessionManager {
    private var activeSession: RemoteSession?
    var onOutput: (@Sendable (String) async -> Void)?

    struct RemoteSession {
        let process: Process
        let stdin: FileHandle
        let projectPath: String
    }

    var hasActiveSession: Bool { activeSession != nil }
    var activeProject: String? { activeSession?.projectPath }

    /// Start a new remote Claude session in the given project directory.
    func start(projectPath: String, prompt: String) async throws {
        // Kill existing session if any
        await stop()

        let claudePath = findClaude()
        guard let claudePath else {
            throw NSError(domain: "RemoteSession", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not find claude executable"
            ])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["-p", prompt, "--output-format", "stream-json"]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        // Inherit user's shell environment for PATH, credentials, etc.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let handler = onOutput
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await handler?(text) }
        }

        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }

        try process.run()
        activeSession = RemoteSession(
            process: process,
            stdin: stdinPipe.fileHandleForWriting,
            projectPath: projectPath
        )
    }

    /// Send a follow-up message to the active session.
    func sendInput(_ text: String) {
        guard let session = activeSession else { return }
        let data = (text + "\n").data(using: .utf8)!
        session.stdin.write(data)
    }

    func stop() async {
        guard let session = activeSession else { return }
        session.process.terminate()
        activeSession = nil
    }

    private func handleTermination() {
        let project = activeSession?.projectPath ?? "unknown"
        activeSession = nil
        Task {
            await onOutput?("Session ended: \(URL(fileURLWithPath: project).lastPathComponent)")
        }
    }

    private nonisolated func findClaude() -> String? {
        // Check common locations
        let candidates = [
            "/usr/local/bin/claude",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.claude/local/claude",
            "/opt/homebrew/bin/claude"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Try which
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["claude"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }
}
```

**Step 2: Commit**

```bash
git add Code/Claudio/Services/RemoteSessionManager.swift
git commit -m "feat: add remote session manager for Telegram-spawned Claude sessions"
```

---

### Task 8: BridgeCoordinator

**Files:**
- Create: `Services/BridgeCoordinator.swift`

**Step 1: Create BridgeCoordinator.swift**

Central router that wires all services together. Manages lifecycle, routes events between hooks/watcher/Telegram, and handles command parsing from incoming Telegram messages.

```swift
import Foundation

@Observable
@MainActor
final class BridgeCoordinator {
    var isEnabled = false
    var isConnected = false
    var botToken: String = ""
    var chatId: Int = 0
    var hooksInstalled = false
    var lastBridgeError: String?

    private var telegram: TelegramService?
    private let hookServer = HookServer()
    private let sessionWatcher = SessionWatcher()
    private let remoteManager = RemoteSessionManager()

    private let settingsKey = "bridge_bot_token"
    private let chatIdKey = "bridge_chat_id"
    private let enabledKey = "bridge_enabled"

    init() {
        botToken = UserDefaults.standard.string(forKey: settingsKey) ?? ""
        chatId = UserDefaults.standard.integer(forKey: chatIdKey)
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    }

    func start() async {
        guard isEnabled, !botToken.isEmpty else { return }

        telegram = TelegramService(token: botToken)
        if chatId != 0 {
            await telegram?.setChatId(chatId)
        }

        // Start hook server
        do {
            try await hookServer.start()
        } catch {
            lastBridgeError = "Hook server: \(error.localizedDescription)"
        }

        // Wire hook events
        await hookServer.setOnEvent { [weak self] event, permId in
            await self?.handleHookEvent(event, permissionId: permId)
        }

        // Wire session watcher
        await sessionWatcher.setOnNewLine { [weak self] line in
            await self?.handleWatchedLine(line)
        }

        // Wire remote session output
        await remoteManager.setOnOutput { [weak self] text in
            await self?.handleRemoteOutput(text)
        }

        // Start Telegram polling
        await telegram?.startPolling { [weak self] update in
            await self?.handleTelegramUpdate(update)
        }

        isConnected = true
    }

    func stop() async {
        await telegram?.stopPolling()
        await hookServer.stop()
        await sessionWatcher.unwatchAll()
        await remoteManager.stop()
        isConnected = false
    }

    func saveBotToken(_ token: String) {
        botToken = token
        UserDefaults.standard.set(token, forKey: settingsKey)
    }

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if enabled { await start() } else { await stop() }
    }

    /// Update watched files based on current active sessions.
    func updateWatchedSessions(_ sessions: [SessionEntry]) async {
        let activePaths = Set(sessions.compactMap { $0.fullPath.isEmpty ? nil : $0.fullPath })
        let currentlyWatched = await sessionWatcher.watchedPaths

        for path in activePaths where !currentlyWatched.contains(path) {
            await sessionWatcher.watchFile(at: path)
        }
        for path in currentlyWatched where !activePaths.contains(path) {
            await sessionWatcher.unwatchFile(at: path)
        }
    }

    // MARK: - Hook events -> Telegram

    private func handleHookEvent(_ event: HookEvent, permissionId: String) async {
        guard let telegram else { return }

        switch event.hookEventName {
        case "PermissionRequest":
            let project = projectName(from: event.cwd)
            let tool = event.toolName ?? "Unknown"
            let input = formatToolInput(event.toolInput)
            let text = "<b>Permission Request — \(project)</b>\nTool: <code>\(tool)</code>\n\(input)"
            let keyboard = TGInlineKeyboardMarkup(inlineKeyboard: [[
                TGInlineKeyboardButton(text: "Approve", callbackData: "perm_allow_\(permissionId)"),
                TGInlineKeyboardButton(text: "Deny", callbackData: "perm_deny_\(permissionId)")
            ]])
            await telegram.send(text, replyMarkup: keyboard)

        case "Notification":
            let project = projectName(from: event.cwd)
            let type = event.notificationType ?? ""
            let msg = event.message ?? ""
            let prefix: String
            switch type {
            case "idle_prompt": prefix = "<b>\(project)</b> — Waiting for input"
            case "elicitation_dialog": prefix = "<b>\(project)</b> — Question"
            case "permission_prompt": prefix = "<b>\(project)</b> — Permission needed"
            default: prefix = "<b>\(project)</b>"
            }
            await telegram.send("\(prefix)\n\(msg)")

        case "Stop":
            let project = projectName(from: event.cwd)
            await telegram.send("<b>\(project)</b> — Agent finished")

        case "SessionStart":
            let project = projectName(from: event.cwd)
            await telegram.send("<b>\(project)</b> — Session started")

        case "SessionEnd":
            let project = projectName(from: event.cwd)
            await telegram.send("<b>\(project)</b> — Session ended")

        default:
            break
        }
    }

    // MARK: - JSONL watcher -> Telegram

    private func handleWatchedLine(_ line: WatchedLine) async {
        guard let telegram else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: line.jsonLine) as? [String: Any] else { return }
        let type = obj["type"] as? String ?? ""

        if type == "assistant", let msg = obj["message"] as? [String: Any],
           let content = msg["content"] as? [[String: Any]] {
            let project = projectName(from: line.sessionPath)
            var texts: [String] = []
            for block in content {
                let blockType = block["type"] as? String
                if blockType == "text", let text = block["text"] as? String {
                    texts.append(text)
                } else if blockType == "tool_use", let name = block["name"] as? String {
                    texts.append("[Tool: \(name)]")
                }
            }
            if !texts.isEmpty {
                let combined = texts.joined(separator: "\n")
                let truncated = combined.count > 3000 ? String(combined.prefix(3000)) + "..." : combined
                await telegram.send("<b>\(project)</b>\n\(escapeHTML(truncated))")
            }
        }
    }

    // MARK: - Telegram -> Claude

    private func handleTelegramUpdate(_ update: TGUpdate) async {
        // Capture chat ID on first message
        if let msg = update.message {
            if chatId == 0 {
                chatId = msg.chat.id
                UserDefaults.standard.set(chatId, forKey: chatIdKey)
                await telegram?.setChatId(chatId)
                await telegram?.send("Connected. Chat ID: \(chatId)")
                return
            }

            guard msg.chat.id == chatId else { return }

            if let text = msg.text {
                await handleTextCommand(text)
            }
        }

        if let callback = update.callbackQuery {
            await handleCallback(callback)
        }
    }

    private func handleTextCommand(_ text: String) async {
        if text.hasPrefix("/run ") {
            let parts = text.dropFirst(5).components(separatedBy: " ")
            guard parts.count >= 2 else {
                await telegram?.send("Usage: /run {project} {prompt}")
                return
            }
            let project = parts[0]
            let prompt = parts.dropFirst().joined(separator: " ")
            let projectPath = resolveProjectPath(project)
            guard let projectPath else {
                await telegram?.send("Project not found: \(project)")
                return
            }
            do {
                try await remoteManager.start(projectPath: projectPath, prompt: prompt)
                await telegram?.send("Started remote session: <b>\(project)</b>")
            } catch {
                await telegram?.send("Failed to start: \(error.localizedDescription)")
            }
        } else if text == "/stop" {
            await remoteManager.stop()
            await telegram?.send("Remote session stopped")
        } else if text == "/status" {
            let remote = await remoteManager.hasActiveSession
            let watched = await sessionWatcher.watchedPaths.count
            await telegram?.send("Bridge: active\nWatched sessions: \(watched)\nRemote session: \(remote ? "running" : "none")")
        } else if await remoteManager.hasActiveSession {
            // Forward text to active remote session
            await remoteManager.sendInput(text)
        }
    }

    private func handleCallback(_ callback: TGCallbackQuery) async {
        guard let data = callback.data else { return }

        if data.hasPrefix("perm_allow_") || data.hasPrefix("perm_deny_") {
            let allow = data.hasPrefix("perm_allow_")
            let permId = String(data.dropFirst(allow ? 11 : 9))
            await hookServer.resolvePermission(id: permId, allow: allow)
            try? await telegram?.answerCallbackQuery(id: callback.id, text: allow ? "Approved" : "Denied")
            // Remove buttons
            if let msg = callback.message {
                try? await telegram?.editMessageReplyMarkup(chatId: msg.chat.id, messageId: msg.messageId)
            }
        }
    }

    // MARK: - Remote session output -> Telegram

    private func handleRemoteOutput(_ text: String) async {
        guard let telegram else { return }
        // Stream JSON lines from claude --output-format stream-json
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let type = obj["type"] as? String
                if type == "assistant", let content = obj["content"] as? String, !content.isEmpty {
                    await telegram.send(escapeHTML(content))
                } else if type == "result", let result = obj["result"] as? String {
                    await telegram.send("<b>Result:</b>\n\(escapeHTML(result))")
                }
            }
        }
    }

    // MARK: - Helpers

    private func projectName(from path: String?) -> String {
        guard let path else { return "Unknown" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func formatToolInput(_ input: [String: AnyCodable]?) -> String {
        guard let input else { return "" }
        if let cmd = input["command"]?.stringValue {
            return "Command: <code>\(escapeHTML(String(cmd.prefix(200))))</code>"
        }
        if let path = input["file_path"]?.stringValue {
            return "File: <code>\(escapeHTML(path))</code>"
        }
        return ""
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func resolveProjectPath(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchDirs = [
            "\(home)/Documents/Code/Python",
            "\(home)/Documents/Code/XCode",
            "\(home)/Documents/Code/P5JS",
            "\(home)/Documents/Code/PlatformIO",
            "\(home)/Documents/Code"
        ]
        for dir in searchDirs {
            let candidate = "\(dir)/\(name)"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Hook installation

    func installHooks() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let settingsPath = "\(home)/.claude/settings.json"
        let fm = FileManager.default

        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        let hookBase = "curl -s -X POST http://localhost:\(19876)"
        let hookConfig: [String: Any] = [
            "PermissionRequest": [["matcher": "", "hooks": [["type": "command", "command": "\(hookBase)/hook/permission -d @-", "timeout": 120]]]],
            "Notification": [["matcher": "", "hooks": [["type": "command", "command": "\(hookBase)/hook/notification -d @-"]]]],
            "Stop": [["matcher": "", "hooks": [["type": "command", "command": "\(hookBase)/hook/stop -d @-"]]]],
            "SessionStart": [["matcher": "", "hooks": [["type": "command", "command": "\(hookBase)/hook/session-start -d @-"]]]],
            "SessionEnd": [["matcher": "", "hooks": [["type": "command", "command": "\(hookBase)/hook/session-end -d @-"]]]]
        ]

        // Merge hooks — preserve existing hooks, add ours
        var existingHooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, config) in hookConfig {
            if var existing = existingHooks[event] as? [[String: Any]] {
                // Check if our hook already exists
                let alreadyInstalled = existing.contains { entry in
                    guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
                    return hooks.contains { ($0["command"] as? String)?.contains("localhost:\(19876)") == true }
                }
                if !alreadyInstalled {
                    existing.append(contentsOf: config as! [[String: Any]])
                    existingHooks[event] = existing
                }
            } else {
                existingHooks[event] = config
            }
        }

        settings["hooks"] = existingHooks

        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            fm.createFile(atPath: settingsPath, contents: data)
        }

        hooksInstalled = true
    }

    func checkHooksInstalled() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let settingsPath = "\(home)/.claude/settings.json"
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else {
            return false
        }
        // Check if our permission hook exists
        guard let permHooks = hooks["PermissionRequest"] as? [[String: Any]] else { return false }
        return permHooks.contains { entry in
            guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
            return hooks.contains { ($0["command"] as? String)?.contains("localhost:19876") == true }
        }
    }
}
```

**Step 2: Wire the `onEvent`/`onNewLine`/`onOutput` setters**

The actor properties use closures. You may need to add setter methods on the actors:

In `HookServer`: `func setOnEvent(_ handler: ...)` is already implied by `var onEvent`.
In `SessionWatcher`: Same pattern with `var onNewLine`.
In `RemoteSessionManager`: Same with `var onOutput`.

If Swift 6 strict concurrency complains about setting closure properties across actor boundaries, wrap them in setter methods.

**Step 3: Verify it compiles**

Build the project. This is the most complex file — expect some concurrency tweaks.

**Step 4: Commit**

```bash
git add Code/Claudio/Services/BridgeCoordinator.swift
git commit -m "feat: add bridge coordinator routing events between services"
```

---

### Task 9: Bridge Settings View

**Files:**
- Create: `Views/BridgeSettingsView.swift`
- Modify: `Views/PopoverView.swift` (add settings section)

**Step 1: Create BridgeSettingsView.swift**

Settings section for the popover: bot token input, connection status, hook installation.

```swift
import SwiftUI

struct BridgeSettingsView: View {
    @Bindable var bridge: BridgeCoordinator
    @State private var tokenInput: String = ""
    @State private var showToken = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Telegram Bridge")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Toggle("Enable", isOn: Binding(
                get: { bridge.isEnabled },
                set: { Task { await bridge.setEnabled($0) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            if bridge.isEnabled {
                // Bot token
                HStack {
                    if showToken {
                        TextField("Bot token", text: $tokenInput)
                            .textFieldStyle(.plain)
                            .font(.caption2)
                            .onSubmit {
                                bridge.saveBotToken(tokenInput)
                            }
                    } else {
                        Text(bridge.botToken.isEmpty ? "No token" : "Token: ****\(String(bridge.botToken.suffix(6)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button(showToken ? "Save" : "Edit") {
                        if showToken {
                            bridge.saveBotToken(tokenInput)
                        } else {
                            tokenInput = bridge.botToken
                        }
                        showToken.toggle()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                }

                // Status
                HStack(spacing: 6) {
                    Circle()
                        .fill(bridge.isConnected ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(bridge.isConnected ? "Connected" : "Disconnected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if bridge.chatId > 0 {
                        Text("Chat: \(bridge.chatId)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Hooks
                HStack {
                    Label(
                        bridge.hooksInstalled ? "Hooks installed" : "Hooks not installed",
                        systemImage: bridge.hooksInstalled ? "checkmark.circle" : "xmark.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(bridge.hooksInstalled ? .secondary : .orange)

                    if !bridge.hooksInstalled {
                        Button("Install") {
                            bridge.installHooks()
                        }
                        .buttonStyle(.glass)
                        .controlSize(.mini)
                    }
                }

                if let error = bridge.lastBridgeError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            bridge.hooksInstalled = bridge.checkHooksInstalled()
        }
    }
}
```

**Step 2: Add to PopoverView**

In `PopoverView.swift`, add the bridge settings section after `sessionsSection` and before `footerSection`:

```swift
// In PopoverView body, inside the VStack:
BridgeSettingsView(bridge: viewModel.bridge)
```

This requires `viewModel` to expose a `bridge` property (done in Task 10).

**Step 3: Commit**

```bash
git add Code/Claudio/Views/BridgeSettingsView.swift
git commit -m "feat: add Telegram bridge settings UI"
```

---

### Task 10: Integration into AppViewModel and ClaudioApp

**Files:**
- Modify: `ViewModel/AppViewModel.swift`
- Modify: `Views/PopoverView.swift`

**Step 1: Add BridgeCoordinator to AppViewModel**

In `AppViewModel.swift`:

- Add property: `let bridge = BridgeCoordinator()`
- In `startPolling()`, after existing setup, call `Task { await bridge.start() }`
- In `stopPolling()`, call `Task { await bridge.stop() }`
- In `refresh()`, after `activeSessions` is updated, call `await bridge.updateWatchedSessions(activeSessions)`

```swift
// In startPolling(), after the otel Task block:
Task { await bridge.start() }

// In stopPolling(), after otelReceiver.stop():
Task { await bridge.stop() }

// In refresh(), after activeSessions = await sessionService.getActiveSessions():
await bridge.updateWatchedSessions(activeSessions)
```

**Step 2: Add bridge section to PopoverView**

In `PopoverView.swift` body VStack, add between `sessionsSection` and `footerSection`:

```swift
BridgeSettingsView(bridge: viewModel.bridge)
```

**Step 3: Verify it compiles and launches**

Build and run. Verify:
- App launches normally
- Bridge settings section appears in popover
- Toggle enable/disable works
- Entering a bot token and saving works

**Step 4: Commit**

```bash
git add Code/Claudio/ViewModel/AppViewModel.swift Code/Claudio/Views/PopoverView.swift
git commit -m "feat: integrate bridge coordinator into app lifecycle"
```

---

### Task 11: Popover Height Adjustment

**Files:**
- Modify: `ClaudioApp.swift`

**Step 1: Increase popover frame height**

The popover is currently 520px tall. With the new bridge settings section, increase to ~600px or make it flexible:

In `ClaudioApp.swift`, change `.frame(width: 320, height: 520)` to `.frame(width: 320, height: 620)`.

**Step 2: Commit**

```bash
git add Code/Claudio/ClaudioApp.swift
git commit -m "style: increase popover height for bridge settings"
```

---

### Task 12: End-to-End Manual Testing

**No files changed — manual verification.**

**Step 1: Create Telegram bot**

1. Open Telegram, search for @BotFather
2. Send `/newbot`
3. Choose name: "Claudio Bridge"
4. Choose username: something unique like `claudio_bridge_bot`
5. Copy the bot token

**Step 2: Configure in Claudio**

1. Open Claudio popover
2. Enable the Telegram Bridge toggle
3. Click "Edit" next to token, paste token, click "Save"
4. Open Telegram, send `/start` to your new bot
5. Verify Claudio shows "Connected" with your chat ID

**Step 3: Install hooks**

1. Click "Install" next to "Hooks not installed"
2. Verify `~/.claude/settings.json` now contains the hook configuration
3. Check with: `cat ~/.claude/settings.json | python3 -m json.tool`

**Step 4: Test permission forwarding**

1. Start a Claude Code session in terminal
2. Do something that requires permission (e.g., run a bash command in default mode)
3. Verify Telegram receives the permission request with Approve/Deny buttons
4. Tap Approve in Telegram
5. Verify Claude Code proceeds

**Step 5: Test notifications**

1. Let Claude Code finish a task
2. Verify Telegram receives "Agent finished" message
3. Verify JSONL watcher forwards assistant messages

**Step 6: Test remote session**

1. In Telegram, send: `/run jkbClaudio what files are in this project`
2. Verify Claude starts and output appears in Telegram
3. Send `/stop` to end the session

**Step 7: Test stdin injection (if using tmux)**

1. Start Claude Code in a tmux session
2. Let it go idle
3. Reply from Telegram
4. Verify text appears in the tmux session

---

### Task 13: Final Commit and Cleanup

**Step 1: Review all new files**

Verify line counts are reasonable (no file over 600 lines per CLAUDE.md rules).

**Step 2: Final commit**

```bash
git add -A
git commit -m "feat: complete Telegram bridge for two-way Claude Code messaging"
```
