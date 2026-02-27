import Foundation
import SwiftUI

@Observable
@MainActor
final class AppViewModel {
    var fiveHourUtilization: Double = 0
    var fiveHourResetsAt: Date?
    var weeklyUtilization: Double = 0
    var weeklyResetsAt: Date?
    var opusUtilization: Double = 0

    var activeSessions: [SessionEntry] = []
    var weeklyStats = WeeklyStats()

    var isConnected = false
    var lastError: String?
    var isLoading = false

    private let usageService = UsageService()
    private let sessionService = SessionService()
    private let otelReceiver = OTelReceiver()
    var otelConnected = false
    private var pollTimer: Timer?

    var menuBarText: String {
        if !isConnected { return "" }
        return "\(Int(weeklyUtilization))%"
    }

    var menuBarColor: Color {
        if weeklyUtilization >= 80 { return .red }
        if weeklyUtilization >= 60 { return .yellow }
        return .white
    }

    func startPolling() {
        Task { await refresh() }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refresh() }
        }

        Task {
            do {
                try await otelReceiver.start()
                otelConnected = true
            } catch {
                otelConnected = false
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        Task { await otelReceiver.stop() }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let usage = try await usageService.fetchUsage()
            fiveHourUtilization = usage.fiveHour?.utilization ?? 0
            fiveHourResetsAt = usage.fiveHour?.resetsAtDate
            weeklyUtilization = usage.sevenDay?.utilization ?? 0
            weeklyResetsAt = usage.sevenDay?.resetsAtDate
            opusUtilization = usage.sevenDayOpus?.utilization ?? 0
            isConnected = true
            lastError = nil
        } catch {
            isConnected = false
            lastError = error.localizedDescription
        }

        activeSessions = await sessionService.getActiveSessions()
        weeklyStats = await sessionService.getWeeklyStats()
    }
}
