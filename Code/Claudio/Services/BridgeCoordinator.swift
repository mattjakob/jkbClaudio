import AppKit
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
    var isFinalizingSetup = false
    var disabledFilters: Set<String> = []

    private var telegram: TelegramService?
    private let hookServer = HookServer()
    private let sessionWatcher = SessionWatcher()

    private var sessionSlots: [SessionSlot] = []
    private var nextSlotNumber: Int = 1

    private struct SessionSlot {
        let number: Int
        let name: String
        let pid: Int
        let jsonlPath: String
        let cwd: String
        let elapsedSeconds: Int
    }

    private static let tokenKey = "bridge_bot_token"
    private static let chatIdKey = "bridge_chat_id"
    private static let enabledKey = "bridge_enabled"
    private static let filtersKey = "bridge_disabled_filters"
    private static let hookPort: UInt16 = 19876

    // MARK: - Message filters

    enum MessageFilter: String, CaseIterable, Sendable {
        case permissionRequests
        case inputNeeded
        case questions
        case agentFinished
        case sessions
        case sessionOutput

        var label: String {
            switch self {
            case .permissionRequests: "Permission Requests"
            case .inputNeeded: "Input Needed"
            case .questions: "Questions"
            case .agentFinished: "Agent Finished"
            case .sessions: "Sessions"
            case .sessionOutput: "Session Output"
            }
        }

        var icon: String {
            switch self {
            case .permissionRequests: "lock.shield"
            case .inputNeeded: "exclamationmark.bubble"
            case .questions: "questionmark.bubble"
            case .agentFinished: "stop.circle"
            case .sessions: "play.circle"
            case .sessionOutput: "text.bubble"
            }
        }

        var subtitle: String {
            switch self {
            case .permissionRequests: "Approve or deny tool usage"
            case .inputNeeded: "Agent is waiting for input"
            case .questions: "Agent is asking a question"
            case .agentFinished: "Agent has stopped"
            case .sessions: "Session started or ended"
            case .sessionOutput: "Live text from sessions"
            }
        }
    }

    func isFilterEnabled(_ filter: MessageFilter) -> Bool {
        !disabledFilters.contains(filter.rawValue)
    }

    func setFilter(_ filter: MessageFilter, enabled: Bool) {
        if enabled {
            disabledFilters.remove(filter.rawValue)
        } else {
            disabledFilters.insert(filter.rawValue)
        }
        UserDefaults.standard.set(Array(disabledFilters), forKey: Self.filtersKey)
        // Sync hooks to match new filter state
        if hooksInstalled { syncHooks() }
    }

    /// Returns true if the given hook event is needed based on current filter state.
    private func isHookNeeded(_ event: String) -> Bool {
        switch event {
        case "PermissionRequest": return isFilterEnabled(.permissionRequests)
        case "Notification": return isFilterEnabled(.inputNeeded) || isFilterEnabled(.questions)
        case "Stop": return isFilterEnabled(.agentFinished)
        case "SessionStart", "SessionEnd": return isFilterEnabled(.sessions)
        default: return false
        }
    }

    init() {
        botToken = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
        chatId = UserDefaults.standard.integer(forKey: Self.chatIdKey)
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let saved = UserDefaults.standard.stringArray(forKey: Self.filtersKey) ?? []
        disabledFilters = Set(saved)
    }

    // MARK: - Lifecycle

    func validateConnection() async {
        guard let telegram, await telegram.isConfigured else {
            isConnected = false
            return
        }
        do {
            _ = try await telegram.getMe()
            isConnected = true
            lastBridgeError = nil
        } catch {
            isConnected = false
            lastBridgeError = "Bot token invalid or API unreachable"
        }
    }

    func start() async {
        guard isEnabled, !botToken.isEmpty else { return }

        telegram = TelegramService(token: botToken)
        if chatId != 0 {
            await telegram?.setChatId(chatId)
        }

        // Validate token before starting services
        do {
            _ = try await telegram!.getMe()
        } catch {
            isConnected = false
            lastBridgeError = "Bot token invalid or API unreachable"
            return
        }

        // Bot commands — must be [a-z0-9_], pure digits may be rejected
        try? await telegram?.setMyCommands([
            TGBotCommand(command: "status", description: "Active sessions"),
            TGBotCommand(command: "start", description: "Show help")
        ])
        try? await telegram?.setMyDescription("Claudio — monitor and control Claude Code sessions.")

        // Set handlers BEFORE starting servers to avoid race conditions
        await hookServer.setOnEvent { [weak self] event, permId in
            await self?.handleHookEvent(event, permissionId: permId)
        }

        await sessionWatcher.setOnNewLine { [weak self] line in
            await self?.handleWatchedLine(line)
        }

        var hookStarted = true
        do {
            try await hookServer.start()
        } catch {
            hookStarted = false
            lastBridgeError = "Hook server: \(error.localizedDescription)"
        }

        await telegram?.startPolling { [weak self] update in
            await self?.handleTelegramUpdate(update)
        }

        isConnected = hookStarted
        if hookStarted { lastBridgeError = nil }
    }

    func stop() async {
        await telegram?.stopPolling()
        await hookServer.stop()
        await sessionWatcher.unwatchAll()
        isConnected = false
    }

    func saveBotToken(_ token: String) async {
        botToken = token
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        if isEnabled {
            await stop()
            await start()
        }
    }

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { await start() } else { await stop() }
    }

    func updateWatchedSessions(_ sessions: [SessionEntry]) async {
        let activePaths = Set(sessions.compactMap { $0.fullPath.isEmpty ? nil : $0.fullPath })
        let currentlyWatched = await sessionWatcher.watchedPaths

        // Update session slots — keep existing numbers, assign new ones, prune ended
        let activeProjectPaths = Set(sessions.map(\.projectPath))
        let usedNumbers = Set<Int>()
        var keptSlots: [SessionSlot] = []
        for slot in sessionSlots {
            if activeProjectPaths.contains(slot.cwd) {
                if let session = sessions.first(where: { $0.projectPath == slot.cwd }) {
                    keptSlots.append(SessionSlot(
                        number: slot.number, name: session.projectName,
                        pid: session.pid, jsonlPath: session.fullPath,
                        cwd: session.projectPath, elapsedSeconds: session.elapsedSeconds
                    ))
                } else {
                    keptSlots.append(slot)
                }
            }
        }
        let keptCwds = Set(keptSlots.map(\.cwd))
        let takenNumbers = usedNumbers.union(keptSlots.map(\.number))
        for session in sessions where !keptCwds.contains(session.projectPath) {
            // Find next available slot number (skip already-taken)
            var n = nextSlotNumber
            var attempts = 0
            while takenNumbers.contains(n) && attempts < 9 {
                n = (n % 9) + 1
                attempts += 1
            }
            keptSlots.append(SessionSlot(
                number: n, name: session.projectName,
                pid: session.pid, jsonlPath: session.fullPath,
                cwd: session.projectPath, elapsedSeconds: session.elapsedSeconds
            ))
            nextSlotNumber = (n % 9) + 1
        }
        sessionSlots = keptSlots

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
        let tag = slotTag(from: event.cwd)

        switch event.hookEventName {
        case "PermissionRequest":
            let tool = event.toolName ?? "Unknown"
            let input = formatToolInput(event.toolInput)
            let text = "\u{1F6A8} \(tag) — Permission Request\nTool: <code>\(tool)</code>\n\(input)"
            let keyboard = TGInlineKeyboardMarkup(inlineKeyboard: [[
                TGInlineKeyboardButton(text: "Approve", callbackData: "perm_allow_\(permissionId)"),
                TGInlineKeyboardButton(text: "Deny", callbackData: "perm_deny_\(permissionId)")
            ]])
            await telegram.send(text, replyMarkup: keyboard)

        case "Notification":
            let type = event.notificationType ?? ""
            switch type {
            case "idle_prompt":
                guard isFilterEnabled(.inputNeeded) else { return }
            case "elicitation_dialog":
                guard isFilterEnabled(.questions) else { return }
            default:
                guard isFilterEnabled(.inputNeeded) else { return }
            }
            let title = event.title
            let msg = event.message ?? ""
            let body = [title, msg.isEmpty ? nil : msg]
                .compactMap { $0 }
                .joined(separator: "\n")
            let prefix: String
            switch type {
            case "idle_prompt": prefix = "\u{1F928} \(tag) — Waiting for input"
            case "elicitation_dialog": prefix = "\u{2753} \(tag) — Question"
            case "permission_prompt": prefix = "\u{1F512} \(tag) — Permission needed"
            default: prefix = "\u{1F514} \(tag) — Notification"
            }
            await telegram.send("\(prefix)\n\(escapeHTML(body))")

        case "Stop":
            await telegram.send("\u{23F8}\u{FE0F} \(tag) — Agent finished")

        case "SessionStart":
            await telegram.send("\u{25B6}\u{FE0F} \(tag) — Session started")

        case "SessionEnd":
            await telegram.send("\u{23F9}\u{FE0F} \(tag) — Session ended")

        default:
            break
        }
    }

    // MARK: - JSONL watcher -> Telegram

    private func handleWatchedLine(_ line: WatchedLine) async {
        guard isFilterEnabled(.sessionOutput) else { return }
        guard let telegram else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: line.jsonLine) as? [String: Any] else { return }
        let type = obj["type"] as? String ?? ""

        if type == "assistant", let msg = obj["message"] as? [String: Any],
           let content = msg["content"] as? [[String: Any]] {
            let texts = content.compactMap { block -> String? in
                guard block["type"] as? String == "text",
                      let text = block["text"] as? String,
                      !text.isEmpty else { return nil }
                return text
            }
            guard !texts.isEmpty else { return }

            let tag = slotTag(fromJsonlPath: line.sessionPath)
            let combined = texts.joined(separator: "\n")
            let truncated = combined.count > 1500 ? String(combined.prefix(1500)) + "..." : combined
            await telegram.send("<b>\(tag)</b>\n\(escapeHTML(truncated))")
        }
    }

    // MARK: - Telegram -> Claude

    private func handleTelegramUpdate(_ update: TGUpdate) async {
        if let msg = update.message {
            if chatId == 0 {
                chatId = msg.chat.id
                UserDefaults.standard.set(chatId, forKey: Self.chatIdKey)
                await telegram?.setChatId(chatId)
                await telegram?.send("Connected. Chat ID: <code>\(chatId)</code>")
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
        // /N message — send to session N
        if let (slotNum, message) = parseSlotCommand(text) {
            guard let slot = findSlot(byNumber: slotNum) else {
                await telegram?.send("Session \(slotNum) not found")
                return
            }
            guard slot.pid > 0 else {
                await telegram?.send("Session \(slotNum) has no active process")
                return
            }
            let result = await StdinInjector.inject(text: message, forPid: String(slot.pid))
            switch result {
            case .success:
                await telegram?.send("Sent to \(slotEmoji(slot.number)) \(escapeHTML(slot.name))")
            case .failed(let err):
                await telegram?.send("Failed: \(escapeHTML(err))")
            }
            return
        }

        if text == "/status" {
            var lines = ["<b>Claudio Bridge</b>\n"]
            if sessionSlots.isEmpty {
                lines.append("No active sessions")
            } else {
                for slot in sessionSlots {
                    let elapsed = friendlyElapsed(slot.elapsedSeconds)
                    lines.append("\(slotEmoji(slot.number)) \(escapeHTML(slot.name)) · \(elapsed)")
                }
            }
            await telegram?.send(lines.joined(separator: "\n"))
        } else if text == "/start" {
            await telegram?.send(
                "Claudio bridge ready.\n\n" +
                "/status — active sessions\n" +
                "/1 msg, /2 msg ... — send to session"
            )
        }
    }

    private func handleCallback(_ callback: TGCallbackQuery) async {
        guard let data = callback.data else { return }

        if data.hasPrefix("perm_allow_") || data.hasPrefix("perm_deny_") {
            let allow = data.hasPrefix("perm_allow_")
            let permId = String(data.dropFirst(allow ? 11 : 9))
            await hookServer.resolvePermission(id: permId, allow: allow)
            try? await telegram?.answerCallbackQuery(id: callback.id, text: allow ? "Approved" : "Denied")
            if let msg = callback.message {
                try? await telegram?.editMessageReplyMarkup(chatId: msg.chat.id, messageId: msg.messageId)
            }
        }
    }

    // MARK: - Hook installation

    private static let hookEvents: [(event: String, path: String, timeout: Int?)] = [
        ("PermissionRequest", "/hook/permission", 120),
        ("Notification",      "/hook/notification", nil),
        ("Stop",              "/hook/stop", nil),
        ("SessionStart",      "/hook/session-start", nil),
        ("SessionEnd",        "/hook/session-end", nil)
    ]

    /// Installs hooks into ~/.claude/settings.json based on current filter state.
    func installHooks() {
        syncHooks()
        hooksInstalled = true
    }

    /// Syncs ~/.claude/settings.json hooks to match current filter state.
    /// Only installs hooks for enabled filters. Removes hooks for disabled ones.
    private func syncHooks() {
        var settings = readSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Remove all Claudio hooks first (clean slate)
        stripOurHooks(&hooks)

        // Re-add only hooks for enabled filters
        let baseURL = "http://localhost:\(Self.hookPort)"
        for (event, path, timeout) in Self.hookEvents {
            guard isHookNeeded(event) else { continue }
            var hookDef: [String: Any] = ["type": "http", "url": "\(baseURL)\(path)"]
            if let timeout { hookDef["timeout"] = timeout }
            let entry: [String: Any] = ["matcher": "", "hooks": [hookDef]]

            if var existing = hooks[event] as? [[String: Any]] {
                existing.append(entry)
                hooks[event] = existing
            } else {
                hooks[event] = [entry]
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        writeSettings(settings)
    }

    /// Called after hooks are installed to configure the bot and trigger macOS permissions.
    func finalizeSetup() async {
        isFinalizingSetup = true
        defer { isFinalizingSetup = false }

        guard let telegram else { return }

        // 1. Set bot profile photo from bundled logo
        if let logoURL = Bundle.main.url(forResource: "logo", withExtension: "png"),
           let logoData = try? Data(contentsOf: logoURL) {
            try? await telegram.setMyProfilePhoto(imageData: logoData)
        }

        // 2. Set bot commands and description
        try? await telegram.setMyCommands([
            TGBotCommand(command: "status", description: "Active sessions"),
            TGBotCommand(command: "start", description: "Show help")
        ])
        try? await telegram.setMyDescription("Claudio — monitor and control Claude Code sessions.")

        // 3. Trigger macOS Automation permission for Terminal.app
        //    This prompts "Claudio wants to control Terminal.app" on first run.
        let _ = await triggerAutomationPermission()

        // 4. Prompt for Accessibility permission if not granted
        if !AXIsProcessTrusted() {
            let _ = AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            )
        }
    }

    /// Run a harmless Terminal.app AppleScript to trigger the Automation permission dialog.
    private func triggerAutomationPermission() async -> Bool {
        await MainActor.run {
            var errorInfo: NSDictionary?
            let script = NSAppleScript(source: """
                tell application "Terminal" to return name
                """)
            let result = script?.executeAndReturnError(&errorInfo)
            return result != nil && errorInfo == nil
        }
    }

    /// Removes all Claudio hooks from ~/.claude/settings.json.
    func uninstallHooks() {
        var settings = readSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else {
            hooksInstalled = false
            return
        }

        stripOurHooks(&hooks)

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        writeSettings(settings)
        hooksInstalled = false
    }

    /// Checks if any Claudio hooks exist in settings (indicates setup was completed).
    func checkHooksInstalled() -> Bool {
        let settings = readSettings()
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }

        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains(where: Self.isOurEntry)
        }
    }

    // MARK: - Settings helpers

    private static var settingsPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/settings.json"
    }

    private func readSettings() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: Self.settingsPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private func writeSettings(_ settings: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        FileManager.default.createFile(atPath: Self.settingsPath, contents: data)
    }

    /// Returns true if a hook definition belongs to Claudio (matches our port in url or command).
    private static func isOurHookDef(_ def: [String: Any]) -> Bool {
        let port = String(hookPort)
        if let cmd = def["command"] as? String, cmd.contains("localhost:\(port)") { return true }
        if let url = def["url"] as? String, url.contains("localhost:\(port)") { return true }
        return false
    }

    /// Returns true if a matcher-group entry contains a Claudio hook.
    private static func isOurEntry(_ entry: [String: Any]) -> Bool {
        guard let defs = entry["hooks"] as? [[String: Any]] else { return false }
        return defs.contains(where: isOurHookDef)
    }

    /// Removes all Claudio entries from a hooks dictionary, cleaning up empty event arrays.
    private func stripOurHooks(_ hooks: inout [String: Any]) {
        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll(where: Self.isOurEntry)
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
    }

    // MARK: - Helpers

    private func slotEmoji(_ n: Int) -> String {
        let clamped = ((n - 1) % 9) + 1
        return "\(clamped)\u{FE0F}\u{20E3}"
    }

    /// Build display tag from a cwd path (hook events). Matches cwd first (exact), then name (ambiguous).
    private func slotTag(from cwd: String?) -> String {
        guard let cwd else { return "Unknown" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        // Prefer exact cwd match, fall back to name match
        if let slot = sessionSlots.first(where: { $0.cwd == cwd })
            ?? sessionSlots.first(where: { $0.name == name }) {
            return "<b>\(slotEmoji(slot.number)) \(escapeHTML(slot.name))</b>"
        }
        return "<b>\(escapeHTML(name))</b>"
    }

    /// Build display tag from a jsonl file path (watcher events)
    private func slotTag(fromJsonlPath path: String) -> String {
        if let slot = sessionSlots.first(where: { $0.jsonlPath == path }) {
            return "\(slotEmoji(slot.number)) \(escapeHTML(slot.name))"
        }
        return escapeHTML(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent)
    }

    private func findSlot(byNumber n: Int) -> SessionSlot? {
        sessionSlots.first(where: { $0.number == n })
    }

    /// Parse "/1 hello" → (1, "hello"). Returns nil if no message body.
    private func parseSlotCommand(_ text: String) -> (Int, String)? {
        guard text.hasPrefix("/"),
              let first = text.dropFirst().first,
              let n = Int(String(first)), n >= 1, n <= 9 else { return nil }
        let rest = text.dropFirst(2)
        guard rest.first == " " else { return nil }
        let message = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty else { return nil }
        return (n, message)
    }

    /// Format elapsed seconds to friendly string like "12m" or "1h 23m"
    private func friendlyElapsed(_ seconds: Int) -> String {
        if seconds >= 3600 {
            return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        }
        return "\(max(seconds / 60, 1))m"
    }

    private func formatToolInput(_ input: [String: AnyCodable]?) -> String {
        guard let input else { return "" }
        if case .string(let cmd) = input["command"] {
            return "Command: <code>\(escapeHTML(String(cmd.prefix(200))))</code>"
        }
        if case .string(let path) = input["file_path"] {
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
}
