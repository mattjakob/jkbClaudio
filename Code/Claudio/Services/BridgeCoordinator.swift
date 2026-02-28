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

    private var sessionSlots: [SessionSlot] = []
    private var nextSlotNumber: Int = 1

    private struct SessionSlot {
        let number: Int
        let name: String
        let pid: Int
        let jsonlPath: String
        let cwd: String
    }

    private static let tokenKey = "bridge_bot_token"
    private static let chatIdKey = "bridge_chat_id"
    private static let enabledKey = "bridge_enabled"
    private static let hookPort: UInt16 = 19876

    init() {
        botToken = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
        chatId = UserDefaults.standard.integer(forKey: Self.chatIdKey)
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
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

        // Auto-configure bot commands and description
        try? await telegram?.setMyCommands([
            TGBotCommand(command: "status", description: "Active sessions"),
            TGBotCommand(command: "run", description: "Start a remote session"),
            TGBotCommand(command: "stop", description: "Stop remote session"),
            TGBotCommand(command: "start", description: "Show help"),
            TGBotCommand(command: "1", description: "Send to session 1"),
            TGBotCommand(command: "2", description: "Send to session 2"),
            TGBotCommand(command: "3", description: "Send to session 3"),
            TGBotCommand(command: "4", description: "Send to session 4")
        ])
        try? await telegram?.setMyDescription("Claudio — monitor and control Claude Code sessions.")

        do {
            try await hookServer.start()
        } catch {
            lastBridgeError = "Hook server: \(error.localizedDescription)"
        }

        await hookServer.setOnEvent { [weak self] event, permId in
            await self?.handleHookEvent(event, permissionId: permId)
        }

        await sessionWatcher.setOnNewLine { [weak self] line in
            await self?.handleWatchedLine(line)
        }

        await remoteManager.setOnOutput { [weak self] text in
            await self?.handleRemoteOutput(text)
        }

        await telegram?.startPolling { [weak self] update in
            await self?.handleTelegramUpdate(update)
        }

        isConnected = true
        lastBridgeError = nil
    }

    func stop() async {
        await telegram?.stopPolling()
        await hookServer.stop()
        await sessionWatcher.unwatchAll()
        await remoteManager.stop()
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
        var keptSlots: [SessionSlot] = []
        for slot in sessionSlots {
            if activeProjectPaths.contains(slot.cwd) {
                // Update with fresh PID/jsonlPath from current session data
                if let session = sessions.first(where: { $0.projectPath == slot.cwd }) {
                    keptSlots.append(SessionSlot(
                        number: slot.number, name: session.projectName,
                        pid: session.pid, jsonlPath: session.fullPath, cwd: session.projectPath
                    ))
                } else {
                    keptSlots.append(slot)
                }
            }
        }
        let keptCwds = Set(keptSlots.map(\.cwd))
        for session in sessions where !keptCwds.contains(session.projectPath) {
            keptSlots.append(SessionSlot(
                number: nextSlotNumber, name: session.projectName,
                pid: session.pid, jsonlPath: session.fullPath, cwd: session.projectPath
            ))
            nextSlotNumber += 1
            if nextSlotNumber > 9 { nextSlotNumber = 1 }
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
            let msg = event.message ?? ""
            let prefix: String
            switch type {
            case "idle_prompt": prefix = "\u{1F928} \(tag) — Waiting for input"
            case "elicitation_dialog": prefix = "\u{2753} \(tag) — Question"
            case "permission_prompt": prefix = "\u{1F512} \(tag) — Permission needed"
            default: prefix = "\u{1F514} \(tag) — Notification"
            }
            await telegram.send("\(prefix)\n\(escapeHTML(msg))")

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
        guard let telegram else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: line.jsonLine) as? [String: Any] else { return }
        let type = obj["type"] as? String ?? ""

        if type == "assistant", let msg = obj["message"] as? [String: Any],
           let content = msg["content"] as? [[String: Any]] {
            // Only collect text blocks — skip tool_use noise
            let texts = content.compactMap { block -> String? in
                guard block["type"] as? String == "text",
                      let text = block["text"] as? String,
                      !text.isEmpty else { return nil }
                return text
            }
            // Skip entirely if no text blocks (all tool_use)
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

        if text.hasPrefix("/run ") {
            let args = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
            let parts = args.components(separatedBy: " ")
            guard parts.count >= 2 else {
                await telegram?.send("Usage: /run {project} {prompt}")
                return
            }
            let project = parts[0]
            let prompt = parts.dropFirst().joined(separator: " ")
            guard let projectPath = resolveProjectPath(project) else {
                await telegram?.send("Project not found: \(project)")
                return
            }
            do {
                try await remoteManager.start(projectPath: projectPath, prompt: prompt)
                await telegram?.send("Started remote session: <b>\(project)</b>")
            } catch {
                await telegram?.send("Failed to start: \(escapeHTML(error.localizedDescription))")
            }
        } else if text == "/stop" {
            await remoteManager.stop()
            await telegram?.send("Remote session stopped")
        } else if text == "/status" {
            let remote = await remoteManager.hasActiveSession
            var lines = ["<b>Claudio Bridge</b>\n"]
            if sessionSlots.isEmpty {
                lines.append("No active sessions")
            } else {
                for slot in sessionSlots {
                    let elapsed = formatElapsed(slot)
                    lines.append("\(slotEmoji(slot.number)) \(escapeHTML(slot.name)) · \(elapsed)")
                }
            }
            lines.append("\nRemote: \(remote ? "running" : "none")")
            await telegram?.send(lines.joined(separator: "\n"))
        } else if text == "/start" {
            await telegram?.send(
                "Claudio bridge ready.\n\n" +
                "/status — active sessions\n" +
                "/1 /2 ... — send to session\n" +
                "/run {project} {prompt} — remote session\n" +
                "/stop — stop remote session"
            )
        } else if await remoteManager.hasActiveSession {
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
            if let msg = callback.message {
                try? await telegram?.editMessageReplyMarkup(chatId: msg.chat.id, messageId: msg.messageId)
            }
        }
    }

    // MARK: - Remote session output

    private func handleRemoteOutput(_ text: String) async {
        guard let telegram else { return }
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

    // MARK: - Hook installation

    private static let hookEvents: [(event: String, path: String, timeout: Int?)] = [
        ("PermissionRequest", "/hook/permission", 120),
        ("Notification",      "/hook/notification", nil),
        ("Stop",              "/hook/stop", nil),
        ("SessionStart",      "/hook/session-start", nil),
        ("SessionEnd",        "/hook/session-end", nil)
    ]

    /// Installs native HTTP hooks into ~/.claude/settings.json.
    /// Removes any stale Claudio hooks (old command-style or HTTP) before adding fresh ones.
    func installHooks() {
        var settings = readSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Remove any existing Claudio hooks first (handles migration from command→http)
        stripOurHooks(&hooks)

        // Install fresh HTTP hooks
        let baseURL = "http://localhost:\(Self.hookPort)"
        for (event, path, timeout) in Self.hookEvents {
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

        settings["hooks"] = hooks
        writeSettings(settings)
        hooksInstalled = true
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

    /// Checks that ALL required hook events are installed (not just PermissionRequest).
    func checkHooksInstalled() -> Bool {
        let settings = readSettings()
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }

        return Self.hookEvents.allSatisfy { event, _, _ in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
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

    /// Build display tag like "1️⃣ jkbClaudio" from a cwd path (hook events)
    private func slotTag(from cwd: String?) -> String {
        guard let cwd else { return "Unknown" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        if let slot = sessionSlots.first(where: { $0.name == name || $0.cwd == cwd }) {
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

    private func formatElapsed(_ slot: SessionSlot) -> String {
        // Find matching session's elapsedSeconds from slots (we don't store it)
        // Use a simpler approach: look up from pid via ps
        let pipe = Pipe()
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(slot.pid), "-o", "etime="]
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run(); ps.waitUntilExit() } catch { return "?" }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty else { return "?" }
        // Convert etime to friendly format
        return friendlyElapsed(output)
    }

    /// Convert ps etime "01:23" / "1-02:03:04" to "1h 23m" style
    private func friendlyElapsed(_ etime: String) -> String {
        var total = 0
        var str = etime
        if let dash = str.firstIndex(of: "-") {
            let days = Int(str[str.startIndex..<dash]) ?? 0
            total += days * 86400
            str = String(str[str.index(after: dash)...])
        }
        let parts = str.components(separatedBy: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: total += parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: total += parts[0] * 60 + parts[1]
        case 1: total += parts[0]
        default: break
        }
        if total >= 3600 {
            return "\(total / 3600)h \((total % 3600) / 60)m"
        }
        return "\(total / 60)m"
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
