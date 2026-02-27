import Foundation

struct UsageReading: Codable, Sendable {
    let timestamp: Date
    let weekly: Double
    let fiveHour: Double
}

struct UsageHistory: Codable, Sendable {
    var readings: [UsageReading] = []
}
