import Foundation

struct HookEvent: Codable, Sendable {
    let sessionId: String?
    let transcriptPath: String?
    let cwd: String?
    let permissionMode: String?
    let hookEventName: String
    let toolName: String?
    let toolInput: [String: AnyCodable]?
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
        case message
        case title
        case notificationType = "notification_type"
    }
}

// MARK: - AnyCodable

enum AnyCodable: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: AnyCodable])
    case array([AnyCodable])
    case null
}

extension AnyCodable: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AnyCodable].self) {
            self = .object(value)
        } else if let value = try? container.decode([AnyCodable].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(
                AnyCodable.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported JSON value"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - HookPermissionResponse

struct HookPermissionResponse: Codable, Sendable {
    let hookSpecificOutput: HookSpecificOutput

    struct HookSpecificOutput: Codable, Sendable {
        let hookEventName: String
        let decision: Decision

        struct Decision: Codable, Sendable {
            let behavior: String
            let message: String?
        }
    }

    static func allow() -> HookPermissionResponse {
        HookPermissionResponse(
            hookSpecificOutput: HookSpecificOutput(
                hookEventName: "PermissionRequest",
                decision: HookSpecificOutput.Decision(behavior: "allow", message: nil)
            )
        )
    }

    static func deny(message: String) -> HookPermissionResponse {
        HookPermissionResponse(
            hookSpecificOutput: HookSpecificOutput(
                hookEventName: "PermissionRequest",
                decision: HookSpecificOutput.Decision(behavior: "deny", message: message)
            )
        )
    }
}
