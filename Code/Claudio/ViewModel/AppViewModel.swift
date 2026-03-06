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
    let bridge = BridgeCoordinator()
    var otelConnected = false
    var extraUsageEnabled = false
    var extraUsageUtilization: Double = 0
    var extraUsageUsedDollars: Double = 0
    var extraUsageLimitDollars: Double = 0
    private var pollTimer: Timer?
    private var activity: NSObjectProtocol?
    private var lastNotifiedWeeklyThreshold: Int = 0
    private var lastNotifiedFiveHourThreshold: Int = 0

    var menuBarText: String {
        if !isConnected { return "" }
        return "\(Int(fiveHourUtilization))%"
    }

    var menuBarColor: Color {
        if fiveHourUtilization >= 70 { return .widgetRed }
        if fiveHourUtilization >= 40 { return .widgetYellow }
        return .white
    }

    var menuBarIcon: String {
        if fiveHourUtilization >= 70 { return "flame.fill" }
        if fiveHourUtilization >= 40 { return "dog.fill" }
        return "leaf.fill"
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

        pollTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
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

        Task { await bridge.start() }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let activity { Foundation.ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        Task { await otelReceiver.stop() }
        Task { await bridge.stop() }
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

            checkUsageMilestones()

            await historyService.record(weekly: weeklyUtilization, fiveHour: fiveHourUtilization)
            usageHistory = await historyService.getReadings()
        } catch UsageError.rateLimited {
            // 429 — keep previous data, no error shown
        } catch {
            isConnected = false
            lastError = error.localizedDescription
        }

        activeSessions = await sessionService.getActiveSessions()
        await bridge.updateWatchedSessions(activeSessions)
    }

    private func checkUsageMilestones() {
        // Weekly: notify at every 10% threshold (10, 20, 30, ...)
        let weeklyThreshold = Int(weeklyUtilization / 10) * 10
        if weeklyThreshold < lastNotifiedWeeklyThreshold {
            lastNotifiedWeeklyThreshold = weeklyThreshold
        } else if weeklyThreshold > lastNotifiedWeeklyThreshold && weeklyThreshold >= 10 {
            lastNotifiedWeeklyThreshold = weeklyThreshold
            NotificationService.shared.sendUsageMilestone(label: "Weekly", percentage: weeklyThreshold)
        }

        // 5-hour: notify at 80% and 90%
        let fiveHourThreshold: Int
        if fiveHourUtilization >= 90 { fiveHourThreshold = 90 }
        else if fiveHourUtilization >= 80 { fiveHourThreshold = 80 }
        else { fiveHourThreshold = 0 }

        if fiveHourThreshold < lastNotifiedFiveHourThreshold {
            lastNotifiedFiveHourThreshold = fiveHourThreshold
        } else if fiveHourThreshold > lastNotifiedFiveHourThreshold {
            lastNotifiedFiveHourThreshold = fiveHourThreshold
            NotificationService.shared.sendUsageMilestone(label: "5-Hour", percentage: fiveHourThreshold)
        }
    }
}
