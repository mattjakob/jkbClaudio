import Foundation

// MARK: - Inbound (stdout from claude process)

enum SDKInbound: @unchecked Sendable {
    case system(sessionId: String, model: String, cwd: String)
    case assistant(contentBlocks: [[String: Any]])
    case result(subtype: String, costUSD: Double, durationMs: Int)
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
            let costUSD = obj["cost_usd"] as? Double ?? 0
            let durationMs = obj["duration_ms"] as? Int ?? 0
            return .result(subtype: subtype, costUSD: costUSD, durationMs: durationMs)

        case "control":
            let requestId = obj["request_id"] as? String ?? ""
            let subtype = obj["subtype"] as? String ?? ""
            let payload = obj["payload"] as? [String: Any] ?? [:]
            return .controlRequest(requestId: requestId, subtype: subtype, payload: payload)

        default:
            return .unknown
        }
    }
}

// MARK: - Outbound (stdin to claude process)

enum SDKOutbound {
    static func controlResponse(requestId: String, behavior: String, updatedInput: [String: Any]? = nil) -> Data? {
        var permission: [String: Any] = ["behavior": behavior]
        if let updatedInput {
            permission["updatedInput"] = updatedInput
        }
        let msg: [String: Any] = [
            "type": "control_response",
            "request_id": requestId,
            "permission": permission
        ]
        return jsonLine(msg)
    }

    static func userMessage(_ text: String) -> Data? {
        let msg: [String: Any] = [
            "type": "user_message",
            "message": text
        ]
        return jsonLine(msg)
    }

    static func interrupt() -> Data? {
        let msg: [String: Any] = [
            "type": "interrupt"
        ]
        return jsonLine(msg)
    }

    private static func jsonLine(_ dict: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: dict, options: []) else {
            return nil
        }
        data.append(0x0A) // newline
        return data
    }
}
