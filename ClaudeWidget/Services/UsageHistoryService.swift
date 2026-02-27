import Foundation

actor UsageHistoryService {
    private let filePath: String
    private var history: UsageHistory

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.filePath = "\(home)/.claude/widget-usage-history.json"
        self.history = UsageHistory()
    }

    func load() {
        guard let data = FileManager.default.contents(atPath: filePath),
              let decoded = try? JSONDecoder.withISO8601.decode(UsageHistory.self, from: data) else {
            return
        }
        history = decoded
    }

    func record(weekly: Double, fiveHour: Double) {
        let reading = UsageReading(timestamp: Date(), weekly: weekly, fiveHour: fiveHour)
        history.readings.append(reading)

        // Keep only last 7 days
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        history.readings = history.readings.filter { $0.timestamp > cutoff }

        save()
    }

    func getReadings() -> [UsageReading] {
        history.readings
    }

    private func save() {
        guard let data = try? JSONEncoder.withISO8601.encode(history) else { return }
        FileManager.default.createFile(atPath: filePath, contents: data)
    }
}

private extension JSONDecoder {
    static let withISO8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let withISO8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
