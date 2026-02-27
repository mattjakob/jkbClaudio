import Foundation

struct SessionEntry: Codable, Identifiable, Sendable {
    let sessionId: String
    let fullPath: String
    let fileMtime: Int64
    let firstPrompt: String?
    let summary: String?
    let messageCount: Int
    let created: String
    let modified: String
    let gitBranch: String?
    let projectPath: String
    let isSidechain: Bool

    var id: String { sessionId }

    var createdDate: Date? {
        ISO8601DateFormatter().date(from: created)
    }

    var modifiedDate: Date? {
        ISO8601DateFormatter().date(from: modified)
    }

    var projectName: String {
        projectPath.components(separatedBy: "/").last ?? projectPath
    }
}

struct SessionsIndex: Codable, Sendable {
    let version: Int
    let entries: [SessionEntry]
}
