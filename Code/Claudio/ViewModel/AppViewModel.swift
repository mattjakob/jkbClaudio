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
    /// Focused window for the chart card AND the menu bar indicator.
    /// Persisted so the selection survives relaunch.
    var chartRange: ChartRange = ChartRange(
        rawValue: UserDefaults.standard.string(forKey: "chartRange") ?? ""
    ) ?? .sevenDay {
        didSet { UserDefaults.standard.set(chartRange.rawValue, forKey: "chartRange") }
    }
    var tokenUsage: TokenUsageSnapshot = .empty
    var scopedWindows: [NamedUsageWindow] = []

    var isConnected = false
    var lastError: String?
    var isLoading = false

    private let usageService = UsageService()
    private let sessionService = SessionService()
    private let historyService = UsageHistoryService()
    let bridge = BridgeCoordinator()
    var extraUsageEnabled = false
    var extraUsageUtilization: Double = 0
    var extraUsageUsedDollars: Double = 0
    var extraUsageLimitDollars: Double = 0
    private let tokenScanner = TokenScanner()
    private var pollTask: Task<Void, Never>?
    private var resetBoundaryTask: Task<Void, Never>?
    private var lastScheduledBoundary: Date?
    private var lastPopoverOpen: Date?
    private var hookObserver: NSObjectProtocol?
    private var scanDebounce: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var lastNotifiedWeeklyThreshold: Int = 0
    private var lastNotifiedFiveHourThreshold: Int = 0

    /// Utilization of whichever window the chart card focuses.
    var focusedUtilization: Double {
        chartRange == .sevenDay ? weeklyUtilization : fiveHourUtilization
    }

    var menuBarText: String {
        if !isConnected { return "" }
        return "\(Int(focusedUtilization))%"
    }

    var menuBarColor: Color {
        if focusedUtilization >= 70 { return .widgetRed }
        if focusedUtilization >= 40 { return .widgetYellow }
        return .white
    }

    var menuBarIcon: String {
        if focusedUtilization >= 70 { return "flame.fill" }
        if focusedUtilization >= 40 { return "dog.fill" }
        return "leaf.fill"
    }

    func startPolling() {
        guard pollTask == nil else { return }

        activity = Foundation.ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Background usage polling"
        )

        hookObserver = NotificationCenter.default.addObserver(
            forName: .claudioHookEvent, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleTokenScan() }
        }

        pollTask = Task { [weak self] in
            guard let self else { return }
            await historyService.load()
            usageHistory = await historyService.getReadings()
            while !Task.isCancelled {
                await refresh()
                let interval = RefreshPolicy.interval(
                    hasActiveSessions: !activeSessions.isEmpty,
                    lastPopoverOpen: lastPopoverOpen,
                    lowPowerMode: Foundation.ProcessInfo.processInfo.isLowPowerModeEnabled,
                    thermalState: Foundation.ProcessInfo.processInfo.thermalState
                )
                try? await Task.sleep(for: .seconds(interval))
            }
        }

        Task { await bridge.start() }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        resetBoundaryTask?.cancel()
        resetBoundaryTask = nil
        if let hookObserver { NotificationCenter.default.removeObserver(hookObserver) }
        hookObserver = nil
        if let activity { Foundation.ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        Task { await bridge.stop() }
    }

    /// Called when the popover becomes visible: bumps cadence and refreshes
    /// immediately (user-initiated fetches bypass the 429 gate).
    func popoverOpened() {
        lastPopoverOpen = Date()
        Task { await refresh(userInitiated: true) }
    }

    func refresh(userInitiated: Bool = false) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let usage = try await usageService.fetchUsage(userInitiated: userInitiated)
            fiveHourUtilization = usage.fiveHour?.utilization ?? 0
            fiveHourResetsAt = usage.fiveHour?.resetsAtDate
            weeklyUtilization = usage.sevenDay?.utilization ?? 0
            weeklyResetsAt = usage.sevenDay?.resetsAtDate
            opusUtilization = usage.sevenDayOpus?.utilization ?? 0
            scopedWindows = usage.scopedWindows()

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
            scheduleResetBoundaryRefresh(for: usage)

            await historyService.record(weekly: weeklyUtilization, fiveHour: fiveHourUtilization)
            usageHistory = await historyService.getReadings()
        } catch UsageError.backoff {
            // Gated (backoff/429 window) — keep previous data silently.
        } catch UsageError.rateLimited {
            // 429 — keep previous data if already connected, show error otherwise
            if !isConnected {
                lastError = "Rate limited — retrying shortly"
            }
        } catch {
            isConnected = false
            lastError = error.localizedDescription
        }

        activeSessions = await sessionService.getActiveSessions()
        await bridge.updateWatchedSessions(activeSessions)
        tokenUsage = await tokenScanner.snapshot()
    }

    /// One-shot refresh just after the nearest window reset so bars drop to
    /// zero promptly instead of waiting out the poll interval.
    private func scheduleResetBoundaryRefresh(for usage: UsageResponse) {
        let boundaries = [usage.fiveHour?.resetsAtDate, usage.sevenDay?.resetsAtDate]
            .compactMap { $0 }
            .filter { $0 > Date() }
        guard let nearest = boundaries.min(), nearest != lastScheduledBoundary else { return }
        lastScheduledBoundary = nearest
        resetBoundaryTask?.cancel()
        resetBoundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(nearest.timeIntervalSinceNow + 2))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Debounced local token rescan on hook events (realtime updates while
    /// a session streams).
    private func scheduleTokenScan() {
        scanDebounce?.cancel()
        scanDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            tokenUsage = await tokenScanner.snapshot()
        }
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
