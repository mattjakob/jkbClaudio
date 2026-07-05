import Foundation

// MARK: - Inbound (stdout from claude process)

/// Messages received from `claude -p ... --output-format stream-json`.
/// Wire formats verified against `anthropics/claude-agent-sdk-python` (see
/// `_internal/query.py` and `client.py`).
enum SDKInbound: @unchecked Sendable {
    case system(sessionId: String, model: String, cwd: String)
    case assistant(contentBlocks: [[String: Any]])
    case result(subtype: String, costUSD: Double, durationMs: Int)
    /// CLI-initiated control request. The CLI delivers these as
    /// `{"type":"control_request","request_id":...,"request":{"subtype":"can_use_tool","tool_name":...,"input":{...}}}`.
    case controlRequest(requestId: String, subtype: String, payload: [String: Any])
    case unknown
}

enum SDKInboundParser {
    static func parse(line: Data) -> SDKInbound {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else {
            return .unknown
        }

        switch type {
        case "system":
            let sessionId = obj["session_id"] as? String ?? ""
            let model = obj["model"] as? String ?? ""
            let cwd = obj["cwd"] as? String ?? ""
            return .system(sessionId: sessionId, model: model, cwd: cwd)

        case "assistant":
            let message = obj["message"] as? [String: Any]
            let content = message?["content"] as? [[String: Any]] ?? []
            return .assistant(contentBlocks: content)

        case "result":
            let subtype = obj["subtype"] as? String ?? ""
            let costUSD = obj["cost_usd"] as? Double ?? obj["total_cost_usd"] as? Double ?? 0
            let durationMs = obj["duration_ms"] as? Int ?? 0
            return .result(subtype: subtype, costUSD: costUSD, durationMs: durationMs)

        case "control_request":
            let requestId = obj["request_id"] as? String ?? ""
            let request = obj["request"] as? [String: Any] ?? [:]
            let subtype = request["subtype"] as? String ?? ""
            return .controlRequest(requestId: requestId, subtype: subtype, payload: request)

        default:
            return .unknown
        }
    }
}

// MARK: - Outbound (stdin to claude process)

enum SDKOutbound {
    /// Builds a successful `control_response` for a `can_use_tool` request.
    /// Wire format (per claude-agent-sdk-python `query.py`):
    /// ```
    /// {"type":"control_response",
    ///  "response":{"subtype":"success",
    ///              "request_id":"...",
    ///              "response":{"behavior":"allow"|"deny", ...}}}
    /// ```
    static func controlResponse(
        requestId: String,
        behavior: String,
        updatedInput: [String: Any]? = nil,
        message: String? = nil
    ) -> Data? {
        var inner: [String: Any] = ["behavior": behavior]
        if let updatedInput { inner["updatedInput"] = updatedInput }
        if let message { inner["message"] = message }

        let envelope: [String: Any] = [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestId,
                "response": inner
            ]
        ]
        return jsonLine(envelope)
    }

    /// Outbound user message in stream-json mode. The CLI's parser expects
    /// the wire shape used by the official SDKs:
    /// ```
    /// {"type":"user",
    ///  "message":{"role":"user","content":"..."},
    ///  "parent_tool_use_id":null,
    ///  "session_id":"..."}
    /// ```
    /// Pass the session ID emitted by the CLI's initial `system` message.
    static func userMessage(_ text: String, sessionId: String = "default") -> Data? {
        let msg: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
            "parent_tool_use_id": NSNull(),
            "session_id": sessionId
        ]
        return jsonLine(msg)
    }

    /// Interrupt control request. Triggers cancellation of the in-flight turn.
    static func interrupt(requestId: String = UUID().uuidString) -> Data? {
        let msg: [String: Any] = [
            "type": "control_request",
            "request_id": requestId,
            "request": ["subtype": "interrupt"]
        ]
        return jsonLine(msg)
    }

    private static func jsonLine(_ dict: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: dict, options: []) else {
            return nil
        }
        data.append(0x0A)
        return data
    }
}
