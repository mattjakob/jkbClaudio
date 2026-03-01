import AppKit
import Foundation
import Security

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
    private var pendingRouteMessage: String?

    private struct SessionSlot {
        let number: Int
        let name: String
        let pid: Int
        let jsonlPath: String
        let cwd: String
        let elapsedSeconds: Int
        let assistantTurns: Int
        let subagentCount: Int
        let cpuPercent: Double
    }

    private static let keychainService = "com.claudio.telegram-bot"
    private static let keychainAccount = "bot_token"
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
        botToken = Self.readTokenFromKeychain() ?? ""
        chatId = UserDefaults.standard.integer(forKey: Self.chatIdKey)
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let saved = UserDefaults.standard.stringArray(forKey: Self.filtersKey) ?? []
        disabledFilters = Set(saved)

        // Migrate token from UserDefaults to Keychain (one-time)
        if botToken.isEmpty, let legacy = UserDefaults.standard.string(forKey: "bridge_bot_token"), !legacy.isEmpty {
            botToken = legacy
            Self.saveTokenToKeychain(legacy)
            UserDefaults.standard.removeObject(forKey: "bridge_bot_token")
        }
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
            TGBotCommand(command: "status", description: "System status"),
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

        // Ensure Accessibility permission is valid (detects stale TCC entries after rebuild)
        if checkHooksInstalled() {
            ensureAccessibility()
        }
    }

    /// If Accessibility isn't trusted, reset any stale TCC entry and prompt the user.
    private func ensureAccessibility() {
        guard !AXIsProcessTrusted() else { return }

        // Reset stale entry (signature changed after rebuild)
        if let bundleId = Bundle.main.bundleIdentifier {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", bundleId]
            reset.standardOutput = FileHandle.nullDevice
            reset.standardError = FileHandle.nullDevice
            try? reset.run()
            reset.waitUntilExit()
        }

        // Prompt user to grant permission
        let _ = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
    }

    func stop() async {
        await telegram?.stopPolling()
        await hookServer.stop()
        await sessionWatcher.unwatchAll()
        isConnected = false
    }

    func saveBotToken(_ token: String) async {
        botToken = token
        Self.saveTokenToKeychain(token)
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
        var keptSlots: [SessionSlot] = []
        for slot in sessionSlots {
            if activeProjectPaths.contains(slot.cwd) {
                if let session = sessions.first(where: { $0.projectPath == slot.cwd }) {
                    keptSlots.append(SessionSlot(
                        number: slot.number, name: session.projectName,
                        pid: session.pid, jsonlPath: session.fullPath,
                        cwd: session.projectPath, elapsedSeconds: session.elapsedSeconds,
                        assistantTurns: session.assistantTurns,
                        subagentCount: session.subagentCount,
                        cpuPercent: session.cpuPercent
                    ))
                } else {
                    keptSlots.append(slot)
                }
            }
        }
        let keptCwds = Set(keptSlots.map(\.cwd))
        let takenNumbers = Set(keptSlots.map(\.number))
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
                cwd: session.projectPath, elapsedSeconds: session.elapsedSeconds,
                assistantTurns: session.assistantTurns,
                subagentCount: session.subagentCount,
                cpuPercent: session.cpuPercent
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

        switch event.hookEventName {
        case "PermissionRequest":
            let tag = slotTag(from: event.cwd, emoji: "\u{26A1}\u{FE0F}")
            let tool = event.toolName ?? "Unknown"
            let input = formatToolInput(event.toolInput)
            let text = "\(tag)\n<pre>Tool: \(escapeHTML(tool))\n\(input)</pre>"
            let keyboard = TGInlineKeyboardMarkup(inlineKeyboard: [[
                TGInlineKeyboardButton(text: "Approve", callbackData: "perm_allow_\(permissionId)"),
                TGInlineKeyboardButton(text: "Deny", callbackData: "perm_deny_\(permissionId)")
            ]])
            await telegram.send(text, replyMarkup: keyboard)

        case "Notification":
            let type = event.notificationType ?? ""
            let emoji: String
            switch type {
            case "idle_prompt":
                guard isFilterEnabled(.inputNeeded) else { return }
                emoji = "\u{1F955}"
            case "elicitation_dialog":
                guard isFilterEnabled(.questions) else { return }
                emoji = "\u{1F430}"
            case "permission_prompt":
                // Handled by PermissionRequest hook with approve/deny buttons
                return
            case "auth_success":
                // Internal event, not useful to forward
                return
            default:
                guard isFilterEnabled(.inputNeeded) else { return }
                emoji = "\u{1F338}"
            }
            let tag = slotTag(from: event.cwd, emoji: emoji)
            let title = event.title
            let msg = event.message ?? ""
            let body = [title, msg.isEmpty ? nil : msg]
                .compactMap { $0 }
                .joined(separator: "\n")
            await telegram.send("\(tag)\n<pre>\(escapeHTML(body))</pre>")

        case "Stop":
            let tag = slotTag(from: event.cwd, emoji: "\u{1FAD6}")
            await telegram.send(tag)

        case "SessionStart":
            let tag = slotTag(from: event.cwd, emoji: "\u{2615}\u{FE0F}")
            await telegram.send(tag)

        case "SessionEnd":
            let tag = slotTag(from: event.cwd, emoji: "\u{1F36D}")
            await telegram.send(tag)

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

            let name: String
            if let slot = sessionSlots.first(where: { $0.jsonlPath == line.sessionPath }) {
                name = "<b>\(slotLabel(slot.number)) | \(escapeHTML(slot.name))</b>"
            } else {
                let dir = URL(fileURLWithPath: line.sessionPath).deletingLastPathComponent().lastPathComponent
                name = "<b>\(escapeHTML(dir))</b>"
            }
            let combined = texts.joined(separator: "\n")
            let truncated = combined.count > 1500 ? String(combined.prefix(1500)) + "..." : combined
            await telegram.send("\(name)\n<pre>\(escapeHTML(truncated))</pre>")
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
            await injectToSlot(slot, message: message)
            return
        }

        if text == "/status" {
            let header = "\u{2728} <b>STATUS</b> \u{2728}"
            if sessionSlots.isEmpty {
                await telegram?.send("\(header)\n\nNo active sessions")
            } else {
                let maxName = 10
                struct Row {
                    let label: String; let name: String; let agents: String; let state: String
                }
                let rows: [Row] = sessionSlots.map { slot in
                    let name = slot.name.count > maxName
                        ? String(slot.name.prefix(maxName - 1)) + "\u{2026}"
                        : slot.name
                    let agents = slot.subagentCount > 0
                        ? "\(slot.subagentCount) subagent\(slot.subagentCount == 1 ? "" : "s")"
                        : "1 agent"
                    let state = slot.cpuPercent > 5
                        ? friendlyElapsed(slot.elapsedSeconds)
                        : "idle"
                    return Row(label: slotLabel(slot.number), name: name, agents: agents, state: state)
                }
                let nameW = rows.map(\.name.count).max() ?? 0
                let agentW = rows.map(\.agents.count).max() ?? 0
                var body: [String] = []
                for row in rows {
                    let n = row.name.padding(toLength: nameW, withPad: " ", startingAt: 0)
                    let a = row.agents.padding(toLength: agentW, withPad: " ", startingAt: 0)
                    body.append("\(row.label) \(escapeHTML(n)) | \(a) | \(row.state)")
                }
                body.append("\nUse /[N] [MESSAGE] to send a message directly to an agent")
                await telegram?.send("\(header)\n<pre>\(body.joined(separator: "\n"))</pre>")
            }
        } else if text == "/start" {
            await telegram?.send(
                "\u{1F3C0}\u{1F94E}\u{26BD}\u{FE0F} <b>CLAUDIO</b> \u{26BD}\u{FE0F}\u{1F94E}\u{1F3C0}\n\n" +
                "<pre>Commands:\n" +
                "/status        active sessions\n" +
                "/[N] [MESSAGE] sends to agent\n" +
                "[MESSAGE]      interactive</pre>"
            )
        } else if !text.hasPrefix("/") {
            // Bare message — route to last active session or prompt
            await routeBareMessage(text)
        }
    }

    private func routeBareMessage(_ text: String) async {
        let activeSlots = sessionSlots.filter { $0.pid > 0 }

        if activeSlots.isEmpty {
            await telegram?.send("No active sessions")
            return
        }

        pendingRouteMessage = text
        let buttons = activeSlots.map { slot in
            TGInlineKeyboardButton(
                text: "\(slotLabel(slot.number)) | \(slot.name)",
                callbackData: "route_\(slot.number)"
            )
        }
        let keyboard = TGInlineKeyboardMarkup(inlineKeyboard: [buttons])
        await telegram?.send("Send to:", replyMarkup: keyboard)
    }

    private func injectToSlot(_ slot: SessionSlot, message: String) async {
        let result = await StdinInjector.inject(text: message, forPid: String(slot.pid))
        switch result {
        case .success:
            await telegram?.send("Sent to \(slotLabel(slot.number)) | \(escapeHTML(slot.name))")
        case .failed(let err):
            await telegram?.send("Failed: \(escapeHTML(err))")
        }
    }

    private func handleCallback(_ callback: TGCallbackQuery) async {
        guard let data = callback.data else { return }

        if data.hasPrefix("perm_allow_") || data.hasPrefix("perm_deny_") {
            let allow = data.hasPrefix("perm_allow_")
            let permId = String(data.dropFirst(allow ? 11 : 10))
            await hookServer.resolvePermission(id: permId, allow: allow)
            try? await telegram?.answerCallbackQuery(id: callback.id, text: allow ? "Approved" : "Denied")
            if let msg = callback.message {
                try? await telegram?.editMessageReplyMarkup(chatId: msg.chat.id, messageId: msg.messageId)
            }
        } else if data.hasPrefix("route_") {
            let numStr = String(data.dropFirst(6))
            guard let num = Int(numStr),
                  let slot = findSlot(byNumber: num),
                  let message = pendingRouteMessage else {
                try? await telegram?.answerCallbackQuery(id: callback.id, text: "Expired")
                return
            }
            pendingRouteMessage = nil
            try? await telegram?.answerCallbackQuery(id: callback.id)
            if let msg = callback.message {
                try? await telegram?.editMessageReplyMarkup(chatId: msg.chat.id, messageId: msg.messageId)
            }
            await injectToSlot(slot, message: message)
        }
    }

    // MARK: - Hook installation

    private enum HookType { case http, command }

    private static let hookEvents: [(event: String, path: String, timeout: Int?, type: HookType)] = [
        ("PermissionRequest", "/hook/permission",     120, .http),
        ("Stop",              "/hook/stop",            nil, .http),
        ("Notification",      "/hook/notification",    nil, .command),
        ("SessionStart",      "/hook/session-start",   nil, .command),
        ("SessionEnd",        "/hook/session-end",     nil, .command)
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
        for (event, path, timeout, hookType) in Self.hookEvents {
            guard isHookNeeded(event) else { continue }
            var hookDef: [String: Any]
            switch hookType {
            case .http:
                hookDef = ["type": "http", "url": "\(baseURL)\(path)"]
                if let timeout { hookDef["timeout"] = timeout }
            case .command:
                hookDef = [
                    "type": "command",
                    "command": "curl -s -X POST -H 'Content-Type: application/json' -d \"$(cat)\" \(baseURL)\(path)"
                ]
                if let timeout { hookDef["timeout"] = timeout }
            }
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
            TGBotCommand(command: "status", description: "System status"),
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

    private func slotLabel(_ n: Int) -> String {
        "\(((n - 1) % 9) + 1)"
    }

    /// Build display tag for a specific event type from a cwd path (hook events).
    private func slotTag(from cwd: String?, emoji: String) -> String {
        guard let cwd else { return "Unknown" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        if let slot = sessionSlots.first(where: { $0.cwd == cwd })
            ?? sessionSlots.first(where: { $0.name == name }) {
            return "\(emoji) <b>\(slotLabel(slot.number)) | \(escapeHTML(slot.name))</b> \(emoji)"
        }
        return "\(emoji) <b>\(escapeHTML(name))</b> \(emoji)"
    }

    /// Build display tag for a specific event type from a jsonl file path (watcher events).
    private func slotTag(fromJsonlPath path: String, emoji: String) -> String {
        if let slot = sessionSlots.first(where: { $0.jsonlPath == path }) {
            return "\(emoji) \(slotLabel(slot.number)) | \(escapeHTML(slot.name)) \(emoji)"
        }
        let name = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return "\(emoji) \(escapeHTML(name)) \(emoji)"
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
            return "Command: \(escapeHTML(String(cmd.prefix(200))))"
        }
        if case .string(let path) = input["file_path"] {
            return "File: \(escapeHTML(path))"
        }
        return ""
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Keychain

    private static func readTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveTokenToKeychain(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        // Try update first, then add
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}
