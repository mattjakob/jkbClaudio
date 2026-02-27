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

    func start() async {
        guard isEnabled, !botToken.isEmpty else { return }

        telegram = TelegramService(token: botToken)
        if chatId != 0 {
            await telegram?.setChatId(chatId)
        }

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
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
    }

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { await start() } else { await stop() }
    }

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
            await telegram.send("\(prefix)\n\(escapeHTML(msg))")

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
            let watched = await sessionWatcher.watchedPaths.count
            await telegram?.send(
                "Bridge: active\nWatched sessions: \(watched)\nRemote session: \(remote ? "running" : "none")"
            )
        } else if text == "/start" {
            // Initial handshake — chatId already captured above
            await telegram?.send("Claudio bridge ready.")
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

    func installHooks() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let settingsPath = "\(home)/.claude/settings.json"
        let fm = FileManager.default

        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        let base = "curl -s -X POST http://localhost:\(Self.hookPort)"
        let hookEvents: [(String, String, Int?)] = [
            ("PermissionRequest", "\(base)/hook/permission -d @-", 120),
            ("Notification", "\(base)/hook/notification -d @-", nil),
            ("Stop", "\(base)/hook/stop -d @-", nil),
            ("SessionStart", "\(base)/hook/session-start -d @-", nil),
            ("SessionEnd", "\(base)/hook/session-end -d @-", nil)
        ]

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for (event, command, timeout) in hookEvents {
            var hookDef: [String: Any] = ["type": "command", "command": command]
            if let timeout { hookDef["timeout"] = timeout }
            let entry: [String: Any] = ["matcher": "", "hooks": [hookDef]]

            if var existing = hooks[event] as? [[String: Any]] {
                let alreadyInstalled = existing.contains { e in
                    guard let h = e["hooks"] as? [[String: Any]] else { return false }
                    return h.contains { ($0["command"] as? String)?.contains("localhost:\(Self.hookPort)") == true }
                }
                if !alreadyInstalled {
                    existing.append(entry)
                    hooks[event] = existing
                }
            } else {
                hooks[event] = [entry]
            }
        }

        settings["hooks"] = hooks

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
              let hooks = settings["hooks"] as? [String: Any],
              let permHooks = hooks["PermissionRequest"] as? [[String: Any]] else {
            return false
        }
        return permHooks.contains { entry in
            guard let h = entry["hooks"] as? [[String: Any]] else { return false }
            return h.contains { ($0["command"] as? String)?.contains("localhost:\(Self.hookPort)") == true }
        }
    }

    // MARK: - Helpers

    private func projectName(from path: String?) -> String {
        guard let path else { return "Unknown" }
        return URL(fileURLWithPath: path).lastPathComponent
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
