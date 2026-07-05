import Foundation

/// Pure policy for the usage poll interval. Fast while Claude Code is in
/// active use, slow when idle, slowest under power/thermal pressure.
enum RefreshPolicy {
    static let fast: TimeInterval = 120
    static let idle: TimeInterval = 900
    static let constrained: TimeInterval = 1800
    static let popoverRecency: TimeInterval = 300

    static func interval(hasActiveSessions: Bool,
                         lastPopoverOpen: Date?,
                         lowPowerMode: Bool,
                         thermalState: Foundation.ProcessInfo.ThermalState,
                         now: Date = Date()) -> TimeInterval {
        if lowPowerMode || thermalState == .serious || thermalState == .critical {
            return constrained
        }
        if hasActiveSessions { return fast }
        if let lastPopoverOpen, now.timeIntervalSince(lastPopoverOpen) < popoverRecency {
            return fast
        }
        return idle
    }
}
