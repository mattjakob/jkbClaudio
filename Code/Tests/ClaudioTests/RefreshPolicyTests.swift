import Testing
import Foundation
@testable import Claudio

@Suite struct RefreshPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func activeSessionsPollFast() {
        #expect(RefreshPolicy.interval(hasActiveSessions: true, lastPopoverOpen: nil,
                                       lowPowerMode: false, thermalState: .nominal, now: now) == 120)
    }

    @Test func recentPopoverPollsFast() {
        let opened = now.addingTimeInterval(-200)
        #expect(RefreshPolicy.interval(hasActiveSessions: false, lastPopoverOpen: opened,
                                       lowPowerMode: false, thermalState: .nominal, now: now) == 120)
    }

    @Test func idlePollsSlow() {
        let opened = now.addingTimeInterval(-3600)
        #expect(RefreshPolicy.interval(hasActiveSessions: false, lastPopoverOpen: opened,
                                       lowPowerMode: false, thermalState: .nominal, now: now) == 900)
        #expect(RefreshPolicy.interval(hasActiveSessions: false, lastPopoverOpen: nil,
                                       lowPowerMode: false, thermalState: .nominal, now: now) == 900)
    }

    @Test func lowPowerAndThermalOverride() {
        #expect(RefreshPolicy.interval(hasActiveSessions: true, lastPopoverOpen: now,
                                       lowPowerMode: true, thermalState: .nominal, now: now) == 1800)
        #expect(RefreshPolicy.interval(hasActiveSessions: true, lastPopoverOpen: now,
                                       lowPowerMode: false, thermalState: .critical, now: now) == 1800)
        #expect(RefreshPolicy.interval(hasActiveSessions: true, lastPopoverOpen: now,
                                       lowPowerMode: false, thermalState: .serious, now: now) == 1800)
    }
}
