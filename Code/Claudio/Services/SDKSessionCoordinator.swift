import Foundation

actor SDKSessionCoordinator {
    struct SpawnedSession {
        let id: String
        let slotNumber: Int
        let projectName: String
        let cwd: String
        let process: ClaudeProcess
    }

    private var sessions: [String: SpawnedSession] = [:]
    private var pendingPermissions: [String: (sessionId: String, requestId: String)] = [:]
    private var nextPermId: Int = 0
    private var nextSlotNumber: Int = 1

    private var onTelegramSend: ((_ text: String, _ replyMarkup: TGInlineKeyboardMarkup?) async -> Void)?

    func setOnTelegramSend(_ handler: @escaping @Sendable (_ text: String, _ replyMarkup: TGInlineKeyboardMarkup?) async -> Void) {
        onTelegramSend = handler
    }

    // MARK: - Public API

    func spawnSession(prompt: String, cwd: String, slotNumber: Int? = nil) async throws -> String {
        let id = UUID().uuidString
        let slot = slotNumber ?? nextSlotNumber
        nextSlotNumber = slot + 1

        let projectName = URL(fileURLWithPath: cwd).lastPathComponent
        let process = ClaudeProcess()

        let session = SpawnedSession(
            id: id, slotNumber: slot, projectName: projectName,
            cwd: cwd, process: process
        )
        sessions[id] = session

        await process.setOnMessage { [weak self] message in
            await self?.handleMessage(message, sessionId: id)
        }
        await process.setOnExit { [weak self] code in
            await self?.handleExit(code, sessionId: id)
        }

        try await process.spawn(prompt: prompt, workingDirectory: cwd)
        return id
    }

    func sendUserMessage(_ text: String, sessionId: String) async {
        guard let session = sessions[sessionId],
              let data = SDKOutbound.userMessage(text) else { return }
        await session.process.write(data)
    }

    func resolvePermission(permId: String, allow: Bool) async {
        guard let pending = pendingPermissions.removeValue(forKey: permId),
              let session = sessions[pending.sessionId] else { return }
        let behavior = allow ? "allow" : "deny"
        guard let data = SDKOutbound.controlResponse(requestId: pending.requestId, behavior: behavior) else { return }
        await session.process.write(data)
    }

    func resolvePermissionWithInput(permId: String, updatedInput: [String: Any]) async {
        guard let pending = pendingPermissions.removeValue(forKey: permId),
              let session = sessions[pending.sessionId] else { return }
        guard let data = SDKOutbound.controlResponse(
            requestId: pending.requestId,
            behavior: "allow",
            updatedInput: updatedInput
        ) else { return }
        await session.process.write(data)
    }

    func interruptSession(_ sessionId: String) async {
        guard let session = sessions[sessionId] else { return }
        await session.process.interrupt()
    }

    func terminateSession(_ sessionId: String) async {
        guard let session = sessions[sessionId] else { return }
        await session.process.terminate()
        sessions.removeValue(forKey: sessionId)
    }

    func activeSessions() -> [(id: String, slotNumber: Int, projectName: String, cwd: String)] {
        sessions.values.map { ($0.id, $0.slotNumber, $0.projectName, $0.cwd) }
    }

    func findBySlotNumber(_ n: Int) -> String? {
        sessions.values.first(where: { $0.slotNumber == n })?.id
    }

    // MARK: - Message routing

    private func handleMessage(_ message: SDKInbound, sessionId: String) async {
        guard let session = sessions[sessionId] else { return }
        let tag = "\u{1F680} <b>\(session.slotNumber) | \(escapeHTML(session.projectName))</b> \u{1F680}"

        switch message {
        case .system:
            await send("\(tag)\nSession started")

        case .assistant(let contentBlocks):
            let texts = contentBlocks.compactMap { block -> String? in
                guard block["type"] as? String == "text",
                      let text = block["text"] as? String,
                      !text.isEmpty else { return nil }
                return text
            }
            guard !texts.isEmpty else { return }
            let combined = texts.joined(separator: "\n")
            let truncated = combined.count > 1500 ? String(combined.prefix(1500)) + "..." : combined
            await send("\(tag)\n<pre>\(escapeHTML(truncated))</pre>")

        case .result(_, let costUSD, let durationMs):
            let costStr = String(format: "$%.4f", costUSD)
            let durStr = durationMs >= 60000
                ? "\(durationMs / 60000)m \((durationMs % 60000) / 1000)s"
                : "\(durationMs / 1000)s"
            await send("\(tag)\nSession completed (\(costStr), \(durStr))")
            sessions.removeValue(forKey: sessionId)

        case .controlRequest(let requestId, let subtype, let payload):
            await handleControlRequest(
                requestId: requestId, subtype: subtype,
                payload: payload, session: session, tag: tag
            )

        case .unknown:
            break
        }
    }

    private func handleControlRequest(
        requestId: String, subtype: String,
        payload: [String: Any], session: SpawnedSession, tag: String
    ) async {
        // can_use_tool is the permission request subtype
        guard subtype == "can_use_tool" else {
            // Auto-approve other control requests (e.g. hook_callback)
            guard let data = SDKOutbound.controlResponse(requestId: requestId, behavior: "allow") else { return }
            await session.process.write(data)
            return
        }

        let toolName = payload["tool_name"] as? String ?? "Unknown"
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]

        let permId = "sdk_\(nextPermId)"
        nextPermId += 1
        pendingPermissions[permId] = (sessionId: session.id, requestId: requestId)

        if toolName == "AskUserQuestion" {
            await handleAskUserQuestion(toolInput: toolInput, permId: permId, tag: tag)
        } else if toolName == "ExitPlanMode" {
            await handleExitPlanMode(toolInput: toolInput, permId: permId, tag: tag)
        } else {
            let inputSummary = formatToolInput(toolInput)
            let text = "\(tag)\n<pre>Tool: \(escapeHTML(toolName))\n\(inputSummary)</pre>"
            let keyboard = TGInlineKeyboardMarkup(inlineKeyboard: [[
                TGInlineKeyboardButton(text: "Approve", callbackData: "sdk_allow_\(permId)"),
                TGInlineKeyboardButton(text: "Deny", callbackData: "sdk_deny_\(permId)")
            ]])
            await send(text, replyMarkup: keyboard)
        }
    }

    private func handleAskUserQuestion(toolInput: [String: Any], permId: String, tag: String) async {
        guard let questions = toolInput["questions"] as? [[String: Any]], !questions.isEmpty else {
            let keyboard = TGInlineKeyboardMarkup(inlineKeyboard: [[
                TGInlineKeyboardButton(text: "Approve", callbackData: "sdk_allow_\(permId)"),
                TGInlineKeyboardButton(text: "Deny", callbackData: "sdk_deny_\(permId)")
            ]])
            await send("\(tag)\n<pre>Question from Claude</pre>", replyMarkup: keyboard)
            return
        }

        for (qIdx, question) in questions.enumerated() {
            let questionText = question["question"] as? String ?? "Choose an option"
            let options = question["options"] as? [[String: Any]] ?? []
            guard !options.isEmpty else { continue }

            var buttons: [TGInlineKeyboardButton] = []
            for (oIdx, option) in options.enumerated() {
                let label = option["label"] as? String ?? "Option \(oIdx + 1)"
                buttons.append(TGInlineKeyboardButton(
                    text: label,
                    callbackData: "sdkask_\(permId)_\(qIdx)_\(oIdx)"
                ))
            }

            let rows = buttons.map { [$0] }
            let keyboard = TGInlineKeyboardMarkup(inlineKeyboard: rows)
            await send("\(tag)\n<b>\(escapeHTML(questionText))</b>", replyMarkup: keyboard)
        }
    }

    private func handleExitPlanMode(toolInput: [String: Any], permId: String, tag: String) async {
        var planExcerpt = ""
        if let plan = toolInput["plan"] as? String {
            planExcerpt = plan.count > 800 ? String(plan.prefix(800)) + "..." : plan
        }

        var promptDescriptions: [String] = []
        if let prompts = toolInput["allowedPrompts"] as? [[String: Any]] {
            for prompt in prompts {
                if let desc = prompt["prompt"] as? String {
                    promptDescriptions.append(desc)
                }
            }
        }

        var text = "\(tag)\n<b>Plan ready to execute</b>"
        if !planExcerpt.isEmpty {
            text += "\n<pre>\(escapeHTML(planExcerpt))</pre>"
        }
        if !promptDescriptions.isEmpty {
            let perms = promptDescriptions.map { "\u{2022} \(escapeHTML($0))" }.joined(separator: "\n")
            text += "\n<b>Requested permissions:</b>\n\(perms)"
        }

        let keyboard = TGInlineKeyboardMarkup(inlineKeyboard: [[
            TGInlineKeyboardButton(text: "Approve", callbackData: "sdk_allow_\(permId)"),
            TGInlineKeyboardButton(text: "Deny", callbackData: "sdk_deny_\(permId)")
        ]])
        await send(text, replyMarkup: keyboard)
    }

    private func handleExit(_ code: Int32, sessionId: String) async {
        guard let session = sessions.removeValue(forKey: sessionId) else { return }
        let tag = "\u{1F680} <b>\(session.slotNumber) | \(escapeHTML(session.projectName))</b> \u{1F680}"
        let status = code == 0 ? "exited" : "exited (code \(code))"
        await send("\(tag)\nProcess \(status)")
    }

    // MARK: - Helpers

    private func send(_ text: String, replyMarkup: TGInlineKeyboardMarkup? = nil) async {
        await onTelegramSend?(text, replyMarkup)
    }

    private func formatToolInput(_ input: [String: Any]) -> String {
        if let cmd = input["command"] as? String {
            return "Command: \(escapeHTML(String(cmd.prefix(200))))"
        }
        if let path = input["file_path"] as? String {
            return "File: \(escapeHTML(path))"
        }
        return ""
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
