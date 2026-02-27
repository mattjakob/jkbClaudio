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
    var usageHistory: [UsageReading] = []
    var chartRange: ChartRange = .sevenDay

    var isConnected = false
    var lastError: String?
    var isLoading = false

    private let usageService = UsageService()
    private let sessionService = SessionService()
    private let historyService = UsageHistoryService()
    private let otelReceiver = OTelReceiver()
    var otelConnected = false
    var extraUsageEnabled = false
    var extraUsageUtilization: Double = 0
    var extraUsageUsedDollars: Double = 0
    var extraUsageLimitDollars: Double = 0
    private var pollTimer: Timer?
    private var activity: NSObjectProtocol?

    var menuBarText: String {
        if !isConnected { return "" }
        return "\(Int(weeklyUtilization))%"
    }

    var menuBarColor: Color {
        if weeklyUtilization >= 80 { return .widgetRed }
        if weeklyUtilization >= 60 { return .widgetYellow }
        return .white
    }

    func startPolling() {
        guard pollTimer == nil else { return }

        activity = Foundation.ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Background usage polling"
        )

        Task {
            await historyService.load()
            usageHistory = await historyService.getReadings()
            await refresh()
        }

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
        if let activity { Foundation.ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
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

            if let extra = usage.extraUsage, extra.isEnabled {
                extraUsageEnabled = true
                extraUsageUtilization = extra.utilization ?? 0
                extraUsageUsedDollars = Double(extra.usedCredits ?? 0) / 100
                extraUsageLimitDollars = Double(extra.monthlyLimit ?? 0) / 100
            } else {
                extraUsageEnabled = false
            }

            isConnected = true
            lastError = nil

            await historyService.record(weekly: weeklyUtilization, fiveHour: fiveHourUtilization)
            usageHistory = await historyService.getReadings()
        } catch {
            isConnected = false
            lastError = error.localizedDescription
        }

        activeSessions = await sessionService.getActiveSessions()
    }
}
