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
    var accessibilityGranted = false
    var lastBridgeError: String?
    var isFinalizingSetup = false
    var disabledFilters: Set<String> = []

    private var telegram: TelegramService?
    private let hookServer = HookServer()
    private let sessionWatcher = SessionWatcher()
    private let sdkCoordinator = SDKSessionCoordinator()

    private var sessionSlots: [SessionSlot] = []
    private var nextSlotNumber: Int = 1
    private var pendingRouteMessage: String?
    private var pendingQuestions: [String: PendingQuestion] = [:]
    private var pendingIdleAsks: [String: PendingIdleAsk] = [:]
    private var idleAskCounter = 0
    private var lastIdleAskKey: String?

    /// Tracks a pending AskUserQuestion so callbacks can resolve it with the right answer.
    private struct PendingQuestion {
        let permissionId: String
        let questions: [[String: Any]]   // raw questions array from tool_input
        let originalInput: [String: AnyCodable]  // full tool_input for updatedInput response
    }

    /// Tracks a pending idle AskUserQuestion so callbacks can inject the selected option.
    private struct PendingIdleAsk {
        let pid: Int
        let optionCount: Int
    }

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
            TGBotCommand(command: "new", description: "Spawn a headless session"),
            TGBotCommand(command: "stop", description: "Stop a spawned session"),
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

        await sdkCoordinator.setOnTelegramSend { [weak self] (text: String, markup: TGInlineKeyboardMarkup?) in
            guard let self else { return }
            await self.telegram?.send(text, replyMarkup: markup)
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

        // Re-sync hooks on startup to pick up any code changes
        if checkHooksInstalled() {
            syncHooks()
            ensureAccessibility()
        }
    }

    /// Updates the `accessibilityGranted` observable property.
    func checkAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Prompts the user to grant Accessibility permission, resetting stale TCC entries first.
    func promptAccessibility() {
        // Reset stale entry (signature changed after rebuild)
        if !AXIsProcessTrusted(), let bundleId = Bundle.main.bundleIdentifier {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", bundleId]
            reset.standardOutput = FileHandle.nullDevice
            reset.standardError = FileHandle.nullDevice
            try? reset.run()
            reset.waitUntilExit()
        }

        let _ = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        checkAccessibility()
    }

    /// If Accessibility isn't trusted, reset any stale TCC entry and prompt the user.
    private func ensureAccessibility() {
        guard !AXIsProcessTrusted() else {
            accessibilityGranted = true
            return
        }
        promptAccessibility()
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
        // Only keep slots for sessions with a running process
        let activeSessions = sessions.filter { $0.pid > 0 }
        let activeProjectPaths = Set(activeSessions.map(\.projectPath))
        var keptSlots: [SessionSlot] = []
        for slot in sessionSlots {
            if activeProjectPaths.contains(slot.cwd) {
                if let session = activeSessions.first(where: { $0.projectPath == slot.cwd }) {
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
        for session in activeSessions where !keptCwds.contains(session.projectPath) {
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
            let tag = slotTag(from: event.cwd, transcriptPath: event.transcriptPath, emoji: "\u{26A1}\u{FE0F}")
            let tool = event.toolName ?? "Unknown"

            if tool == "AskUserQuestion" {
                await handleAskUserQuestion(event, tag: tag, permissionId: permissionId)
            } else if tool == "ExitPlanMode" {
                await handleExitPlanMode(event, tag: tag, permissionId: permissionId)
            } else {
                let input = formatToolInput(event.toolInput)
                let text = "\(tag)\n<pre>Tool: \(escapeHTML(tool))\n\(input)</pre>"
                let keyboard = TGInlineKeyboardMarkup(inlineKeyboard: [[
                    TGInlineKeyboardButton(text: "Approve", callbackData: "perm_allow_\(permissionId)"),
                    TGInlineKeyboardButton(text: "Deny", callbackData: "perm_deny_\(permissionId)")
                ]])
                await telegram.send(text, replyMarkup: keyboard)
            }

        case "Notification":
            let type = event.notificationType ?? ""
            let emoji: String
            switch type {
            case "idle_prompt":
                guard isFilterEnabled(.inputNeeded) else { return }
                if let tp = event.transcriptPath,
                   let questions = extractAskFromTranscript(tp) {
                    let key = "\(tp):\(questions.first?["question"] as? String ?? "")"
                    guard key != lastIdleAskKey else { return }
                    lastIdleAskKey = key
                    await handleIdleAskUserQuestion(event: event, questions: questions)
                    return
                }
                let genericKey = "idle:\(event.transcriptPath ?? event.cwd ?? "")"
                guard genericKey != lastIdleAskKey else { return }
                lastIdleAskKey = genericKey
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
            let tag = slotTag(from: event.cwd, transcriptPath: event.transcriptPath, emoji: emoji)
            let title = event.title
            let msg = event.message ?? ""
            let body = [title, msg.isEmpty ? nil : msg]
                .compactMap { $0 }
                .joined(separator: "\n")
            await telegram.send("\(tag)\n<pre>\(escapeHTML(body))</pre>")

        case "Stop":
            let tag = slotTag(from: event.cwd, transcriptPath: event.transcriptPath, emoji: "\u{1FAD6}")
            await telegram.send(tag)

        case "SessionStart":
            let tag = slotTag(from: event.cwd, transcriptPath: event.transcriptPath, emoji: "\u{2615}\u{FE0F}")
            await telegram.send(tag)

        case "SessionEnd":
            let tag = slotTag(from: event.cwd, transcriptPath: event.transcriptPath, emoji: "\u{1F36D}")
            await telegram.send(tag)

        default:
            break
        }
    }

    // MARK: - AskUserQuestion / ExitPlanMode

    private func handleAskUserQuestion(_ event: HookEvent, tag: String, permissionId: String) async {
        guard let telegram else { return }

        // Extract questions array from tool_input
        let questionsRaw = extractQuestionsArray(from: event.toolInput)
        guard !questionsRaw.isEmpty else {
            // Fallback to generic approve/deny if we can't parse
            let text = "\(tag)\n<pre>Question from Claude</pre>"
            let keyboard = TGInlineKeyboardMarkup(inlineKeyboard: [[
                TGInlineKeyboardButton(text: "Approve", callbackData: "perm_allow_\(permissionId)"),
                TGInlineKeyboardButton(text: "Deny", callbackData: "perm_deny_\(permissionId)")
            ]])
            await telegram.send(text, replyMarkup: keyboard)
            return
        }

        // Store for callback resolution
        pendingQuestions[permissionId] = PendingQuestion(
            permissionId: permissionId,
            questions: questionsRaw,
            originalInput: event.toolInput ?? [:]
        )

        // For each question, send a message with inline keyboard options
        for (qIdx, question) in questionsRaw.enumerated() {
            let questionText = question["question"] as? String ?? "Choose an option"
            let options = question["options"] as? [[String: Any]] ?? []

            guard !options.isEmpty else { continue }

            var buttons: [TGInlineKeyboardButton] = []
            for (oIdx, option) in options.enumerated() {
                let label = option["label"] as? String ?? "Option \(oIdx + 1)"
                buttons.append(TGInlineKeyboardButton(
                    text: label,
                    callbackData: "ask_\(permissionId)_\(qIdx)_\(oIdx)"
                ))
            }

            // Stack buttons vertically (one per row) for readability
            let rows = buttons.map { [$0] }
            let keyboard = TGInlineKeyboardMarkup(inlineKeyboard: rows)
            let text = "\(tag)\n<b>\(escapeHTML(questionText))</b>"
            await telegram.send(text, replyMarkup: keyboard)
        }
    }

    private func handleExitPlanMode(_ event: HookEvent, tag: String, permissionId: String) async {
        guard let telegram else { return }

        // Extract plan text from tool_input
        var planExcerpt = ""
        if let input = event.toolInput,
           case .string(let plan) = input["plan"] {
            planExcerpt = plan.count > 800 ? String(plan.prefix(800)) + "..." : plan
        }

        // Extract allowedPrompts descriptions if available
        var promptDescriptions: [String] = []
        if let input = event.toolInput,
           case .array(let prompts) = input["allowedPrompts"] {
            for prompt in prompts {
                if case .object(let obj) = prompt,
                   case .string(let desc) = obj["prompt"] {
                    promptDescriptions.append(desc)
                }
            }
        }

        var text = "\(tag)\n<b>Plan ready to execute</b>"
        if !planExcerpt.isEmpty {
            text += "\n<pre>\(escapeHTML(planExcerpt))</pre>"
        }
        if !promptDescriptions.isEmpty {
            let perms = promptDescriptions.map { "• \(escapeHTML($0))" }.joined(separator: "\n")
            text += "\n<b>Requested permissions:</b>\n\(perms)"
        }

        let keyboard = TGInlineKeyboardMarkup(inlineKeyboard: [[
            TGInlineKeyboardButton(text: "Approve", callbackData: "perm_allow_\(permissionId)"),
            TGInlineKeyboardButton(text: "Deny", callbackData: "perm_deny_\(permissionId)")
        ]])
        await telegram.send(text, replyMarkup: keyboard)
    }

    /// Extracts the questions array from AskUserQuestion tool_input.
    private func extractQuestionsArray(from input: [String: AnyCodable]?) -> [[String: Any]] {
        guard let input, case .array(let questions) = input["questions"] else { return [] }
        return questions.compactMap { item -> [String: Any]? in
            guard case .object(let obj) = item else { return nil }
            return anyCodableToDict(obj)
        }
    }

    /// Converts AnyCodable dictionary to plain [String: Any] for easier access.
    private func anyCodableToDict(_ obj: [String: AnyCodable]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in obj {
            switch value {
            case .string(let s): result[key] = s
            case .int(let i): result[key] = i
            case .double(let d): result[key] = d
            case .bool(let b): result[key] = b
            case .array(let arr): result[key] = arr.map(anyCodableToAny)
            case .object(let o): result[key] = anyCodableToDict(o)
            case .null: break
            }
        }
        return result
    }

    private func anyCodableToAny(_ value: AnyCodable) -> Any {
        switch value {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let arr): return arr.map(anyCodableToAny)
        case .object(let o): return anyCodableToDict(o)
        case .null: return NSNull()
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
        // /N message — check SDK sessions first, then terminal sessions
        if let (slotNum, message) = parseSlotCommand(text) {
            if let sdkSessionId = await sdkCoordinator.findBySlotNumber(slotNum) {
                await sdkCoordinator.sendUserMessage(message, sessionId: sdkSessionId)
                await telegram?.send("Sent to spawned session \(slotNum)")
                return
            }
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

        if text.hasPrefix("/new ") {
            await handleNewCommand(String(text.dropFirst(5)))
            return
        }

        if text.hasPrefix("/stop ") {
            await handleStopCommand(String(text.dropFirst(6)))
            return
        }

        if text == "/status" {
            await handleStatusCommand()
        } else if text == "/start" {
            await telegram?.send(
                "\u{1F3C0}\u{1F94E}\u{26BD}\u{FE0F} <b>CLAUDIO</b> \u{26BD}\u{FE0F}\u{1F94E}\u{1F3C0}\n\n" +
                "<pre>Commands:\n" +
                "/status        active sessions\n" +
                "/new [PROMPT]  spawn headless session\n" +
                "/stop [N]      stop spawned session\n" +
                "/[N] [MESSAGE] sends to agent\n" +
                "[MESSAGE]      interactive</pre>"
            )
        } else if !text.hasPrefix("/") {
            await routeBareMessage(text)
        }
    }

    // MARK: - /new command

    private func handleNewCommand(_ args: String) async {
        let trimmed = args.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            await telegram?.send("Usage: /new &lt;prompt&gt; or /new /path prompt")
            return
        }

        var cwd: String
        var prompt: String

        if trimmed.hasPrefix("/") {
            // /new /path/to/project prompt text
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            if parts.count == 2 {
                cwd = String(parts[0])
                prompt = String(parts[1])
            } else {
                cwd = FileManager.default.homeDirectoryForCurrentUser.path
                prompt = trimmed
            }
        } else {
            cwd = FileManager.default.homeDirectoryForCurrentUser.path
            prompt = trimmed
        }

        // Verify cwd exists
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue {
            await telegram?.send("Directory not found: \(escapeHTML(cwd))")
            return
        }

        do {
            let sessionId = try await sdkCoordinator.spawnSession(prompt: prompt, cwd: cwd)
            _ = sessionId // session ID tracked internally
        } catch {
            await telegram?.send("Failed to spawn: \(escapeHTML(error.localizedDescription))")
        }
    }

    // MARK: - /stop command

    private func handleStopCommand(_ args: String) async {
        let trimmed = args.trimmingCharacters(in: .whitespaces)
        guard let n = Int(trimmed), n >= 1 else {
            await telegram?.send("Usage: /stop &lt;N&gt;")
            return
        }

        guard let sessionId = await sdkCoordinator.findBySlotNumber(n) else {
            await telegram?.send("No spawned session \(n)")
            return
        }

        await sdkCoordinator.interruptSession(sessionId)
        await telegram?.send("Interrupted session \(n)")
    }

    // MARK: - /status command

    private func handleStatusCommand() async {
        let header = "\u{2728} <b>STATUS</b> \u{2728}"
        let sdkSessions = await sdkCoordinator.activeSessions()

        if sessionSlots.isEmpty && sdkSessions.isEmpty {
            await telegram?.send("\(header)\n\nNo active sessions")
            return
        }

        let maxName = 10
        struct Row {
            let label: String; let name: String; let detail: String; let state: String
        }
        var rows: [Row] = sessionSlots.map { slot in
            let name = slot.name.count > maxName
                ? String(slot.name.prefix(maxName - 1)) + "\u{2026}"
                : slot.name
            let total = slot.subagentCount + 1
            let agents = total == 1 ? "1 agent" : "\(total) agents"
            let state = slot.cpuPercent > 5
                ? friendlyElapsed(slot.elapsedSeconds)
                : "idle"
            return Row(label: slotLabel(slot.number), name: name, detail: agents, state: state)
        }
        for sdk in sdkSessions {
            let name = sdk.projectName.count > maxName
                ? String(sdk.projectName.prefix(maxName - 1)) + "\u{2026}"
                : sdk.projectName
            rows.append(Row(label: "\(sdk.slotNumber)", name: name, detail: "spawned", state: "active"))
        }

        let nameW = rows.map(\.name.count).max() ?? 0
        let detailW = rows.map(\.detail.count).max() ?? 0
        var body: [String] = []
        for row in rows {
            let n = row.name.padding(toLength: nameW, withPad: " ", startingAt: 0)
            let d = row.detail.padding(toLength: detailW, withPad: " ", startingAt: 0)
            body.append("\(row.label) \(escapeHTML(n)) | \(d) | \(row.state)")
        }
        body.append("\nUse /[N] [MESSAGE] to send a message to an agent")
        await telegram?.send("\(header)\n<pre>\(body.joined(separator: "\n"))</pre>")
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
            await telegram?.send("Sent to \(escapeHTML(slot.name))")
        case .failed(let err):
            await telegram?.send("Failed: \(escapeHTML(err))")
        }
    }

    private func handleCallback(_ callback: TGCallbackQuery) async {
        guard let data = callback.data else { return }

        // SDK spawned session callbacks
        if data.hasPrefix("sdk_allow_") || data.hasPrefix("sdk_deny_") {
            let allow = data.hasPrefix("sdk_allow_")
            let permId = String(data.dropFirst(allow ? 10 : 9))
            await sdkCoordinator.resolvePermission(permId: permId, allow: allow)
            try? await telegram?.answerCallbackQuery(id: callback.id, text: allow ? "Approved" : "Denied")
            if let msg = callback.message {
                try? await telegram?.editMessageReplyMarkup(chatId: msg.chat.id, messageId: msg.messageId)
            }
            return
        }

        if data.hasPrefix("sdkask_") {
            await handleSdkAskCallback(callback, data: data)
            return
        }

        if data.hasPrefix("idle_") {
            await handleIdleAskCallback(callback, data: data)
            return
        } else if data.hasPrefix("ask_") {
            await handleAskCallback(callback, data: data)
            return
        } else if data.hasPrefix("perm_allow_") || data.hasPrefix("perm_deny_") {
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

    /// Handles callback from AskUserQuestion inline keyboard.
    /// Callback data format: "ask_{permissionId}_{questionIndex}_{optionIndex}"
    private func handleAskCallback(_ callback: TGCallbackQuery, data: String) async {
        // Callback data: "ask_perm_N_qIdx_oIdx"
        // permId contains underscores (e.g. "perm_3"), so split from the end
        let components = data.components(separatedBy: "_")
        guard components.count >= 4,
              let oIdx = Int(components.last!),
              let qIdx = Int(components[components.count - 2]) else {
            try? await telegram?.answerCallbackQuery(id: callback.id, text: "Invalid")
            return
        }
        // permId is everything between "ask_" and the last two "_N_N" segments
        let permId = components[1..<(components.count - 2)].joined(separator: "_")

        guard let pending = pendingQuestions[permId] else {
            try? await telegram?.answerCallbackQuery(id: callback.id, text: "Expired")
            return
        }

        guard qIdx < pending.questions.count else {
            try? await telegram?.answerCallbackQuery(id: callback.id, text: "Invalid question")
            return
        }

        let question = pending.questions[qIdx]
        let questionText = question["question"] as? String ?? ""
        let options = question["options"] as? [[String: Any]] ?? []

        guard oIdx < options.count else {
            try? await telegram?.answerCallbackQuery(id: callback.id, text: "Invalid option")
            return
        }

        let selectedLabel = options[oIdx]["label"] as? String ?? ""

        // Build answers dict: map question text → selected label
        var answers: [String: AnyCodable] = [:]
        if case .object(let existingAnswers) = pending.originalInput["answers"] {
            answers = existingAnswers
        }
        answers[questionText] = .string(selectedLabel)

        // Rebuild the full tool_input with answers filled in
        var updatedInput = pending.originalInput
        updatedInput["answers"] = .object(answers)

        // For single-question flows, resolve immediately
        // For multi-question, we'd need to track partial answers — keep it simple for now
        pendingQuestions.removeValue(forKey: permId)
        let response = HookPermissionResponse.allowWithInput(
            updatedInput.reduce(into: [:]) { $0[$1.key] = $1.value }
        )
        await hookServer.resolvePermission(id: permId, response: response)

        try? await telegram?.answerCallbackQuery(id: callback.id, text: selectedLabel)
        if let msg = callback.message {
            try? await telegram?.editMessageReplyMarkup(chatId: msg.chat.id, messageId: msg.messageId)
        }
    }

    // MARK: - SDK AskUserQuestion callback

    /// Handles callback from SDK AskUserQuestion inline keyboard.
    /// Callback data format: "sdkask_{permId}_{questionIndex}_{optionIndex}"
    private func handleSdkAskCallback(_ callback: TGCallbackQuery, data: String) async {
        // Format: "sdkask_sdk_N_qIdx_oIdx"
        // permId contains underscores (e.g. "sdk_3"), so split from the end
        let components = data.components(separatedBy: "_")
        guard components.count >= 4,
              let oIdx = Int(components.last!),
              let qIdx = Int(components[components.count - 2]) else {
            try? await telegram?.answerCallbackQuery(id: callback.id, text: "Invalid")
            return
        }
        // permId is everything between "sdkask_" and the last two "_N_N" segments
        let permId = components[1..<(components.count - 2)].joined(separator: "_")

        // Build updatedInput with the selected answer
        let updatedInput: [String: Any] = [
            "answers": [
                "question": "\(qIdx)",
                "selected": "\(oIdx)"
            ]
        ]
        await sdkCoordinator.resolvePermissionWithInput(permId: permId, updatedInput: updatedInput)

        let label = "Option \(oIdx + 1)"
        try? await telegram?.answerCallbackQuery(id: callback.id, text: label)
        if let msg = callback.message {
            try? await telegram?.editMessageReplyMarkup(chatId: msg.chat.id, messageId: msg.messageId)
        }
    }

    // MARK: - Idle AskUserQuestion (from JSONL transcript)

    /// Sends inline keyboard buttons for an AskUserQuestion found in the JSONL transcript.
    private func handleIdleAskUserQuestion(event: HookEvent, questions: [[String: Any]]) async {
        guard let telegram else { return }
        guard let slot = findSlot(byCwd: event.cwd, transcriptPath: event.transcriptPath) else { return }
        let tag = slotTag(from: event.cwd, transcriptPath: event.transcriptPath, emoji: "\u{1F430}")

        for question in questions {
            let questionText = question["question"] as? String ?? "Choose an option"
            let options = question["options"] as? [[String: Any]] ?? []
            guard !options.isEmpty else { continue }

            idleAskCounter += 1
            let askId = String(idleAskCounter)
            pendingIdleAsks[askId] = PendingIdleAsk(pid: slot.pid, optionCount: options.count)

            var buttons: [TGInlineKeyboardButton] = []
            for (oIdx, option) in options.enumerated() {
                let label = option["label"] as? String ?? "Option \(oIdx + 1)"
                buttons.append(TGInlineKeyboardButton(
                    text: label,
                    callbackData: "idle_\(askId)_\(oIdx)"
                ))
            }

            let rows = buttons.map { [$0] }
            let keyboard = TGInlineKeyboardMarkup(inlineKeyboard: rows)
            let text = "\(tag)\n<b>\(escapeHTML(questionText))</b>"
            await telegram.send(text, replyMarkup: keyboard)
        }
    }

    /// Handles callback from idle AskUserQuestion inline keyboard.
    /// Injects the 1-based option number into the session terminal.
    private func handleIdleAskCallback(_ callback: TGCallbackQuery, data: String) async {
        // Format: "idle_{askId}_{optionIndex}"
        let components = data.components(separatedBy: "_")
        guard components.count == 3,
              let oIdx = Int(components[2]),
              let pending = pendingIdleAsks[components[1]] else {
            try? await telegram?.answerCallbackQuery(id: callback.id, text: "Expired")
            return
        }

        guard oIdx < pending.optionCount else {
            try? await telegram?.answerCallbackQuery(id: callback.id, text: "Invalid")
            return
        }

        let askId = components[1]
        pendingIdleAsks.removeValue(forKey: askId)

        // Inject 1-based option number into terminal
        let optionNumber = String(oIdx + 1)
        let result = await StdinInjector.inject(text: optionNumber, forPid: String(pending.pid))

        switch result {
        case .success:
            try? await telegram?.answerCallbackQuery(id: callback.id, text: "Option \(oIdx + 1)")
        case .failed(let err):
            try? await telegram?.answerCallbackQuery(id: callback.id, text: "Failed: \(err)")
        }
        if let msg = callback.message {
            try? await telegram?.editMessageReplyMarkup(chatId: msg.chat.id, messageId: msg.messageId)
        }
    }

    /// Read the last 16KB of a JSONL transcript and find the last actionable tool_use block
    /// (AskUserQuestion or ExitPlanMode).
    private func extractAskFromTranscript(_ path: String) -> [[String: Any]]? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }

        let fileSize = fh.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 16384)
        fh.seek(toFileOffset: fileSize - readSize)
        let data = fh.readDataToEndOfFile()

        guard let chunk = String(data: data, encoding: .utf8) else { return nil }
        let lines = chunk.components(separatedBy: "\n").reversed()

        for line in lines {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let type = obj["type"] as? String ?? ""
            guard type == "assistant" else { continue }

            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }

            for block in content.reversed() {
                guard block["type"] as? String == "tool_use" else { continue }
                let name = block["name"] as? String ?? ""

                if name == "AskUserQuestion",
                   let input = block["input"] as? [String: Any],
                   let questions = input["questions"] as? [[String: Any]],
                   !questions.isEmpty {
                    return questions
                }

                if name == "ExitPlanMode" {
                    return [["question": "Plan ready to execute", "options": [
                        ["label": "Clear context + bypass"],
                        ["label": "Bypass permissions"],
                        ["label": "Manually approve"]
                    ]]]
                }
            }
        }
        return nil
    }

    // MARK: - Hook installation

    private static let hookEvents: [(event: String, path: String, timeout: Int?)] = [
        ("PermissionRequest", "/hook/permission",     120),
        ("Stop",              "/hook/stop",            nil),
        ("Notification",      "/hook/notification",    nil),
        ("SessionStart",      "/hook/session-start",   nil),
        ("SessionEnd",        "/hook/session-end",     nil)
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

        // Re-add only hooks for enabled filters (all HTTP type)
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
            TGBotCommand(command: "status", description: "System status"),
            TGBotCommand(command: "new", description: "Spawn a headless session"),
            TGBotCommand(command: "stop", description: "Stop a spawned session"),
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
        if let url = def["url"] as? String, url.contains("localhost:\(port)") { return true }
        if let cmd = def["command"] as? String, cmd.contains("localhost:\(port)") { return true }
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

    /// Build display tag for a hook event from cwd and/or transcriptPath.
    private func slotTag(from cwd: String?, transcriptPath: String? = nil, emoji: String) -> String {
        if let slot = findSlot(byCwd: cwd, transcriptPath: transcriptPath) {
            return "\(emoji) <b>\(slotLabel(slot.number)) | \(escapeHTML(slot.name))</b> \(emoji)"
        }
        let name = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown"
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

    /// Find a session slot by matching transcriptPath or cwd with multiple strategies.
    private func findSlot(byCwd cwd: String?, transcriptPath: String?) -> SessionSlot? {
        // 1. Match by transcriptPath → jsonlPath (most reliable)
        if let tp = transcriptPath {
            let stdTP = (tp as NSString).standardizingPath
            if let slot = sessionSlots.first(where: { ($0.jsonlPath as NSString).standardizingPath == stdTP }) {
                return slot
            }
        }
        guard let cwd else { return nil }
        let stdCwd = (cwd as NSString).standardizingPath

        // 2. Exact standardized cwd match
        if let slot = sessionSlots.first(where: { ($0.cwd as NSString).standardizingPath == stdCwd }) {
            return slot
        }

        // 3. Parent/child containment check
        if let slot = sessionSlots.first(where: {
            let stdSlotCwd = ($0.cwd as NSString).standardizingPath
            return stdCwd.hasPrefix(stdSlotCwd + "/") || stdSlotCwd.hasPrefix(stdCwd + "/")
        }) {
            return slot
        }

        // 4. lastPathComponent name match
        let name = URL(fileURLWithPath: stdCwd).lastPathComponent
        return sessionSlots.first(where: { $0.name == name })
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
